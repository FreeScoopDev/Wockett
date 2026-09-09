import Foundation
import Observation
import UserNotifications

// MARK: - Seam
//
// Everything the service needs from UNUserNotificationCenter, as a protocol, so
// scheduling logic can be unit-tested against a fake. UNUserNotificationCenter
// already has `requestAuthorization(options:)` and `add(_:)` with these exact
// signatures; the extension below supplies the rest.

protocol NotificationCentering: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePending(withIdentifiers ids: [String])
    func removeDelivered(withIdentifiers ids: [String])
    func pendingIdentifiers() async -> [String]
    func setCategories(_ categories: Set<UNNotificationCategory>)
}

extension UNUserNotificationCenter: NotificationCentering {
    func authorizationStatus() async -> UNAuthorizationStatus { await notificationSettings().authorizationStatus }
    func removePending(withIdentifiers ids: [String]) { removePendingNotificationRequests(withIdentifiers: ids) }
    func removeDelivered(withIdentifiers ids: [String]) { removeDeliveredNotifications(withIdentifiers: ids) }
    func pendingIdentifiers() async -> [String] { await pendingNotificationRequests().map(\.identifier) }
    func setCategories(_ categories: Set<UNNotificationCategory>) { setNotificationCategories(categories) }
}

// MARK: - Kinds
//
// Every notification the app sends, with a STABLE identifier so each one can be
// replaced or cancelled. Identifiers that were already fixed are unchanged;
// hydration and scheduled-route reminders used to be UUIDs and could never be
// cancelled — that is the one deliberate behaviour change here.

enum NotificationKind: Hashable {
    case weeklySummary
    case streakNudge
    case petNudge
    case hydration
    case autoPause
    case routeEvent(String)
    case checkpoint(String)
    case waterBreak(Int)
    case walkReminder(UUID)

    static let waterBreakMax = 12
    static let sessionThread = "wkt.session"

    var identifier: String {
        switch self {
        case .weeklySummary:            return "wkt-weekly-summary"
        case .streakNudge:              return "streak-protection"
        case .petNudge:                 return "pet-nudge"
        case .hydration:                return "hydration"
        case .autoPause:                return "autoPause"
        case .routeEvent(let key):      return "nav-\(key)"
        case .checkpoint(let label):    return "checkpoint-\(label)"
        case .waterBreak(let i):        return "waterBreak-\(i)"
        case .walkReminder(let id):     return "walkReminder-\(id.uuidString)"
        }
    }

    /// UserDefaults key of the Settings toggle that gates this kind, if any.
    /// Absent means the kind is controlled in-session or is always-on.
    var preferenceKey: String? {
        switch self {
        case .weeklySummary: return "notif_weeklySummary"
        case .streakNudge:   return "notif_streakProtection"
        case .petNudge:      return "notif_petNudge"
        case .hydration:     return "notif_hydration"
        default:             return nil
        }
    }

    var category: String? {
        switch self {
        case .streakNudge: return NotificationCategory.streakNudge
        case .petNudge:    return NotificationCategory.petNudge
        case .hydration:   return NotificationCategory.hydration
        case .waterBreak:  return NotificationCategory.waterBreak
        case .walkReminder: return NotificationCategory.walkReminder
        default:           return nil
        }
    }

    /// Grouping in Notification Center. In-session kinds share a thread so a
    /// walk's water breaks and checkpoints stack rather than scatter.
    var threadIdentifier: String {
        switch self {
        case .weeklySummary:                                              return "wkt.digest"
        case .streakNudge, .petNudge:                                     return "wkt.nudges"
        case .hydration, .autoPause, .routeEvent, .checkpoint, .waterBreak: return NotificationKind.sessionThread
        case .walkReminder:                                               return "wkt.reminders"
        }
    }

    /// In-walk kinds break through Focus. The user started the walk, and a water
    /// break, checkpoint, auto-pause or route event is only useful in the moment
    /// it fires. Requires the Time Sensitive entitlement (#21); without it iOS
    /// delivers these at `.active` and says nothing. Nudges and route reminders
    /// stay `.active` — they are Wockett interrupting, not the walk. The weekly
    /// recap is `.passive`. Exhaustive on purpose: a new kind must choose.
    var interruptionLevel: UNNotificationInterruptionLevel {
        switch self {
        case .weeklySummary:                                                return .passive
        case .hydration, .autoPause, .routeEvent, .checkpoint, .waterBreak: return .timeSensitive
        case .streakNudge, .petNudge, .walkReminder:                        return .active
        }
    }

    /// True for kinds that should still banner while the app is in the foreground.
    var bannersInForeground: Bool { threadIdentifier == NotificationKind.sessionThread }
}

/// The Sendable subset of a delivered notification that the action handler
/// needs. UNNotificationContent itself is not Sendable, so the delegate builds
/// this before hopping to the main actor.
struct NotificationSnapshot: Sendable {
    let title: String
    let body: String
    let categoryIdentifier: String
    let threadIdentifier: String
    let interruptionLevel: UNNotificationInterruptionLevel
    let hasSound: Bool

    init(_ content: UNNotificationContent) {
        title = content.title
        body = content.body
        categoryIdentifier = content.categoryIdentifier
        threadIdentifier = content.threadIdentifier
        interruptionLevel = content.interruptionLevel
        hasSound = content.sound != nil
    }
}

// MARK: - Service

@MainActor
@Observable
final class NotificationService {
    static let shared = NotificationService()

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Set by the delegate when the user taps an action that needs the app to
    /// navigate. The app root observes and consumes it.
    private(set) var pendingAction: String?

    /// Every walk reminder the user has set, in the order they were added.
    /// Persisted so Settings can list and delete them; the system holds the
    /// matching pending requests.
    private(set) var walkReminders: [WalkReminder] = []
    static let walkRemindersKey = "walkReminders"

    private let center: NotificationCentering
    private let defaults: UserDefaults

    init(center: NotificationCentering = UNUserNotificationCenter.current(),
         defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.walkRemindersKey),
           let saved = try? JSONDecoder().decode([WalkReminder].self, from: data) {
            walkReminders = saved
        }
    }

    // MARK: Authorization

    /// Authorized, provisional (quiet delivery) or ephemeral all deliver. The old
    /// per-site guards accepted only `.authorized`, which is what made the quiet
    /// path impossible.
    var isDelivering: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    var isFullyAuthorized: Bool { authorizationStatus == .authorized }

    func refreshStatus() async {
        authorizationStatus = await center.authorizationStatus()
    }

    /// First-launch path: ask for quiet delivery without a prompt, once, only if
    /// the user has never been asked. A later full request will prompt normally.
    func requestQuietDeliveryIfNeverAsked() async {
        await refreshStatus()
        guard authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .provisional])
        await refreshStatus()
    }

    /// Settings path: the real prompt. Safe to call from any state.
    @discardableResult
    func requestFullAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        await refreshStatus()
        return granted
    }

    // MARK: Preferences

    func isEnabled(_ kind: NotificationKind) -> Bool {
        guard let key = kind.preferenceKey else { return true }
        return defaults.object(forKey: key) as? Bool ?? true
    }

    // MARK: Scheduling

    /// Builds the content, applies the kind's category / thread / interruption
    /// level, replaces any pending request with the same identifier, and adds.
    /// Skips silently — and cancels any pending copy — when the kind is switched
    /// off in Settings or nothing would be delivered.
    @discardableResult
    func schedule(_ kind: NotificationKind,
                  title: String,
                  body: String,
                  trigger: UNNotificationTrigger?,
                  sound: Bool = true) async -> Bool {
        center.removePending(withIdentifiers: [kind.identifier])
        guard isEnabled(kind) else { return false }
        await refreshStatus()
        guard isDelivering else { return false }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        if let category = kind.category { content.categoryIdentifier = category }
        content.threadIdentifier = kind.threadIdentifier
        content.interruptionLevel = kind.interruptionLevel

        let request = UNNotificationRequest(identifier: kind.identifier, content: content, trigger: trigger)
        do { try await center.add(request); return true } catch { return false }
    }

    func cancel(_ kind: NotificationKind) {
        center.removePending(withIdentifiers: [kind.identifier])
    }

    func cancelWaterBreaks() {
        center.removePending(withIdentifiers: (1...NotificationKind.waterBreakMax).map { NotificationKind.waterBreak($0).identifier })
    }

    func pending() async -> [String] { await center.pendingIdentifiers() }

    // MARK: Categories & actions

    func registerCategories() {
        let snooze    = UNNotificationAction(identifier: NotificationAction.snooze10,  title: "Snooze 10 min", options: [])
        let markDone  = UNNotificationAction(identifier: NotificationAction.markDone,  title: "Done",          options: [])
        let startWalk = UNNotificationAction(identifier: NotificationAction.startWalk, title: "Start Walk",    options: [.foreground])
        let dismiss   = UNNotificationAction(identifier: NotificationAction.dismiss,   title: "Dismiss",       options: [])
        center.setCategories([
            UNNotificationCategory(identifier: NotificationCategory.waterBreak,  actions: [snooze, markDone],  intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationCategory.streakNudge, actions: [startWalk, dismiss], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationCategory.petNudge,    actions: [startWalk, dismiss], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationCategory.hydration,   actions: [markDone, dismiss],  intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationCategory.walkReminder, actions: [startWalk, dismiss], intentIdentifiers: [], options: [])
        ])
    }

    /// Called by the delegate. Snooze re-schedules the same content in 10 minutes;
    /// Done clears the delivered notification and any snooze of it; Start Walk
    /// records an action for the app root to route.
    func handle(actionIdentifier: String, notificationIdentifier id: String, snapshot: NotificationSnapshot) async {
        switch actionIdentifier {
        case NotificationAction.snooze10:
            let content = UNMutableNotificationContent()
            content.title = snapshot.title
            content.body = snapshot.body
            content.categoryIdentifier = snapshot.categoryIdentifier
            content.threadIdentifier = snapshot.threadIdentifier
            content.interruptionLevel = snapshot.interruptionLevel
            if snapshot.hasSound { content.sound = .default }
            let request = UNNotificationRequest(identifier: "\(id)-snooze", content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false))
            try? await center.add(request)
        case NotificationAction.markDone:
            center.removeDelivered(withIdentifiers: [id])
            center.removePending(withIdentifiers: ["\(id)-snooze"])
        case NotificationAction.startWalk:
            pendingAction = NotificationAction.startWalk
        default:
            break
        }
    }

    func consumePendingAction() -> String? {
        defer { pendingAction = nil }
        return pendingAction
    }

    // MARK: Walk reminders

    /// The user asked for something, so this is a moment for the real prompt if
    /// delivery is only quiet. Returns false when alerts are denied (iOS will not
    /// re-prompt; Settings is the only way back) or the request could not be
    /// added. One reminder per route: a second for the same route replaces it.
    @discardableResult
    func addWalkReminder(_ reminder: WalkReminder) async -> Bool {
        await refreshStatus()
        if !isFullyAuthorized {
            guard await requestFullAuthorization() else { return false }
        }
        if let route = reminder.routeName,
           let existing = walkReminders.first(where: { $0.routeName == route }) {
            removeWalkReminder(id: existing.id)
        }
        let added = await schedule(.walkReminder(reminder.id), title: reminder.notificationTitle,
                                   body: reminder.notificationBody, trigger: reminder.trigger)
        guard added else { return false }
        walkReminders.append(reminder)
        persistWalkReminders()
        return true
    }

    func removeWalkReminder(id: UUID) {
        cancel(.walkReminder(id))
        walkReminders.removeAll { $0.id == id }
        persistWalkReminders()
    }

    /// One-off reminders whose time has passed have fired (or been missed) and
    /// only clutter the list. Called at launch and when Settings appears.
    func pruneExpiredWalkReminders(now: Date = Date()) {
        let expired = walkReminders.filter { $0.isExpired(at: now) }
        guard !expired.isEmpty else { return }
        walkReminders.removeAll { $0.isExpired(at: now) }
        persistWalkReminders()
    }

    private func persistWalkReminders() {
        if let data = try? JSONEncoder().encode(walkReminders) {
            defaults.set(data, forKey: Self.walkRemindersKey)
        }
    }
}
