import Foundation

// MARK: - The Apple Watch glance (feat/watch-complications)
//
// What the watch face complications and Smart Stack widgets show: today's
// steps against the goal, and the top pets' steps today. The phone reads
// Health and owns the pets, so it builds one `WatchGlanceSnapshot` and sends
// it over WatchConnectivity; the Watch app stores the newest one in the
// watch's App Group container and the widget extension draws it.
//
// Compiled into the iPhone app, the Watch app and the watch widget
// extension (a root file, like WatchWalkLink.swift), so all three read the
// same types and no key is typed twice. Everything the watch decides from a
// snapshot (stale day, placeholder, when to send) lives here so the app's
// unit tests cover it; the widget views only draw it.
//
// Foundation only, and `nonisolated` because the app target defaults to the
// main actor and WatchConnectivity calls back on a background queue.

/// One pet as the watch shows it. Only these five fields go to the watch:
/// never the owner's name or phone number.
nonisolated struct WatchGlancePet: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var emoji: String
    /// The pet's steps today, as the phone's pet screens count them.
    var steps: Int
    /// The pet's daily goal.
    var goal: Int
}

/// Today's numbers, made on the phone.
nonisolated struct WatchGlanceSnapshot: Codable, Equatable, Sendable {
    static let maxPets = 3

    /// The person's steps in the phone's step day; nil when the phone has
    /// no count yet (Health not read), so the watch shows a placeholder
    /// rather than a false 0.
    var steps: Int?
    var goal: Int
    /// The phone's step day, "yyyy-MM-dd" in its time zone. The step day
    /// starts at 3 AM (`StepManager.trackingDayStart`).
    var day: String
    /// When the phone's step day ends (the next 3 AM): from then the steps
    /// shown are 0 until the phone sends again.
    var stepsUntil: Date
    /// When the pets' day ends (the next midnight: pet steps count the
    /// calendar day, `PetStore.todaySteps`).
    var petsUntil: Date
    /// When the phone made it. The watch keeps the newest.
    var madeAt: Date
    /// Up to `maxPets`, most steps today first, then the phone's list order.
    var pets: [WatchGlancePet]

    /// Builds the snapshot from what the phone knows. `pets` come in the
    /// phone's list order; they are sorted by steps (a tie keeps list
    /// order) and capped at `maxPets`.
    static func make(steps: Int?, goal: Int, pets: [WatchGlancePet], dayStart: Date,
                     now: Date, calendar: Calendar = .current) -> WatchGlanceSnapshot {
        let ranked = pets.enumerated()
            .sorted { $0.element.steps != $1.element.steps ? $0.element.steps > $1.element.steps : $0.offset < $1.offset }
            .prefix(maxPets)
            .map(\.element)
        let stepsUntil = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let midnight = calendar.startOfDay(for: now)
        let petsUntil = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight.addingTimeInterval(86_400)
        return WatchGlanceSnapshot(steps: steps.map { max(0, $0) }, goal: max(0, goal),
                                   day: dayKey(dayStart, calendar: calendar),
                                   stepsUntil: stepsUntil, petsUntil: petsUntil, madeAt: now, pets: Array(ranked))
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Whether the steps reached the goal.
    var goalReached: Bool { goal > 0 && (steps ?? 0) >= goal }

    /// The same numbers, whenever each was made: nothing new to send.
    func sameContent(as other: WatchGlanceSnapshot) -> Bool {
        var copy = self
        copy.madeAt = other.madeAt
        return copy == other
    }

    /// The newer of two snapshots (by `madeAt`); the first on a tie.
    static func newest(_ a: WatchGlanceSnapshot?, _ b: WatchGlanceSnapshot?) -> WatchGlanceSnapshot? {
        guard let a else { return b }
        guard let b else { return a }
        return b.madeAt > a.madeAt ? b : a
    }
}

// MARK: - Wire format

/// The snapshot travels as one JSON blob under its own key, in the
/// application context (next to the walk state, `WatchWire.key`), in a
/// complication user info, and in the reply to the watch's request for state.
nonisolated enum WatchGlanceWire {
    static let key = "wockett.watch.glance.v1"

    static func payload(_ snapshot: WatchGlanceSnapshot) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(snapshot) else { return [:] }
        return [key: data]
    }

    static func decode(from dictionary: [String: Any]) -> WatchGlanceSnapshot? {
        guard let data = dictionary[key] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchGlanceSnapshot.self, from: data)
    }
}

// MARK: - When the phone sends

/// What the phone may send now.
nonisolated struct WatchGlanceLinkStatus: Equatable, Sendable {
    /// WatchConnectivity is active, a watch is paired and the Watch app is
    /// installed on it.
    var canSend: Bool
    /// One of Wockett's complications is on the active watch face.
    var complicationEnabled: Bool
    /// `remainingComplicationUserInfoTransfers` (50 a day on the face).
    var remainingTransfers: Int
    /// WatchConnectivity has not finished activating yet, so whether a
    /// glance can go is not known: worth waiting a moment for. False once
    /// activation completed (paired or not) and where there is no session.
    var activationPending = false

    /// Nothing can go: no paired watch, no Watch app, or no session at all.
    static let unavailable = WatchGlanceLinkStatus(canSend: false, complicationEnabled: false, remainingTransfers: 0)
    /// The session is still activating.
    static let activating = WatchGlanceLinkStatus(canSend: false, complicationEnabled: false, remainingTransfers: 0,
                                                  activationPending: true)
}

/// The application context carries every change (it replaces the last and
/// costs no budget). A complication transfer wakes the watch at once but
/// has a daily budget, so it goes only while a complication is on the face,
/// with budget left, and at most every `complicationInterval`, except right
/// away for a new day, a changed goal, or the goal first reached. Pure, for
/// the tests. Codable: the phone keeps it across launches (a background
/// refresh is often a fresh launch), so the interval holds.
nonisolated struct WatchGlanceSendPolicy: Codable, Equatable, Sendable {
    static let complicationInterval: TimeInterval = 15 * 60

    struct Decision: Equatable, Sendable {
        var context: Bool
        var complication: Bool
        static let none = Decision(context: false, complication: false)
    }

    private(set) var lastContext: WatchGlanceSnapshot?
    private(set) var lastComplication: WatchGlanceSnapshot?
    private(set) var lastComplicationAt: Date?

    func decide(_ snapshot: WatchGlanceSnapshot, now: Date, status: WatchGlanceLinkStatus) -> Decision {
        guard status.canSend else { return .none }
        let context = lastContext.map { !snapshot.sameContent(as: $0) } ?? true
        return Decision(context: context, complication: complicationDue(snapshot, now: now, status: status))
    }

    private func complicationDue(_ snapshot: WatchGlanceSnapshot, now: Date, status: WatchGlanceLinkStatus) -> Bool {
        guard status.complicationEnabled, status.remainingTransfers > 0 else { return false }
        guard let last = lastComplication, let at = lastComplicationAt else { return true }
        guard !snapshot.sameContent(as: last) else { return false }
        if snapshot.day != last.day || snapshot.goal != last.goal { return true }
        if snapshot.goalReached, !last.goalReached { return true }
        return now.timeIntervalSince(at) >= Self.complicationInterval
    }

    /// The complication has not had the latest numbers (a change came
    /// inside the interval): worth asking again once the interval is up.
    var complicationBehind: Bool {
        guard let lastContext, let lastComplication else { return false }
        return !lastContext.sameContent(as: lastComplication)
    }

    /// Whether the 1 s check could send a held-back transfer now: one is
    /// owed, a complication is on the face, budget is left and the interval
    /// is up. Cheap (no snapshot is built), so the check asks this first and
    /// does nothing once the complication left the face or the budget is
    /// spent. A new day, goal change or goal reached comes with a change
    /// that sends through `decide` anyway.
    func complicationCatchUpDue(now: Date, status: WatchGlanceLinkStatus) -> Bool {
        guard status.canSend, status.complicationEnabled, status.remainingTransfers > 0,
              complicationBehind else { return false }
        guard let at = lastComplicationAt else { return true }
        return now.timeIntervalSince(at) >= Self.complicationInterval
    }

    /// A newly activated session sends the context again whatever was sent
    /// before; the complication's interval still holds.
    mutating func forgetContext() {
        lastContext = nil
    }

    mutating func didSend(_ snapshot: WatchGlanceSnapshot, _ decision: Decision, at now: Date) {
        if decision.context { lastContext = snapshot }
        if decision.complication {
            lastComplication = snapshot
            lastComplicationAt = now
        }
    }
}

// MARK: - The watch's copy

/// Where the Watch app keeps the newest snapshot for the widget extension:
/// the watch's own App Group container (`AppGroup.identifier`; a group
/// container is per device, so this is not the phone's).
nonisolated enum WatchGlanceStorage {
    static func load(from defaults: UserDefaults?) -> WatchGlanceSnapshot? {
        guard let data = defaults?.data(forKey: AppGroup.WatchKey.glance) else { return nil }
        return try? JSONDecoder().decode(WatchGlanceSnapshot.self, from: data)
    }

    /// Stores `snapshot` unless the stored one is newer or the same.
    /// Returns whether it stored it (and the widgets should reload).
    @discardableResult
    static func save(_ snapshot: WatchGlanceSnapshot, to defaults: UserDefaults?) -> Bool {
        guard let defaults else { return false }
        let stored = load(from: defaults)
        if let stored, stored.madeAt >= snapshot.madeAt { return false }
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: AppGroup.WatchKey.glance)
        return true
    }
}

// MARK: - What the complications show

nonisolated enum WatchGlanceDisplay {
    static let placeholderText = "Open Wockett on your iPhone"
    static let noPetsText = "Add a pet in Wockett on your iPhone."

    struct Steps: Equatable, Sendable {
        var steps: Int
        var goal: Int

        var reached: Bool { goal > 0 && steps >= goal }
        /// 0...1 for a gauge.
        var fraction: Double { goal > 0 ? min(1, Double(steps) / Double(goal)) : 0 }
        /// Whole percent of the goal, uncapped ("124%").
        var percent: Int { goal > 0 ? Int((Double(steps) * 100 / Double(goal)).rounded(.down)) : 0 }
    }

    enum StepsGlance: Equatable, Sendable {
        /// Nothing from the phone yet: "Open Wockett on your iPhone".
        case placeholder
        case steps(Steps)
    }

    enum PetsGlance: Equatable, Sendable {
        case placeholder
        /// The phone has no pets: "Add a pet in Wockett on your iPhone."
        case noPets
        case pets([WatchGlancePet])
    }

    /// The rectangle fits two pets with their gauges on the smallest watch
    /// (42 mm); the snapshot may carry up to `WatchGlanceSnapshot.maxPets`.
    static let rectangularPetLimit = 2

    /// The pets the rectangular complication draws: the top two.
    static func rectangularPets(_ pets: [WatchGlancePet]) -> [WatchGlancePet] {
        Array(pets.prefix(rectangularPetLimit))
    }

    /// The steps to show at `now`. A snapshot from an earlier step day shows
    /// 0 with its goal, never the old count.
    static func steps(_ snapshot: WatchGlanceSnapshot?, now: Date) -> StepsGlance {
        guard let snapshot, let steps = snapshot.steps else { return .placeholder }
        let stale = now >= snapshot.stepsUntil
        return .steps(Steps(steps: stale ? 0 : steps, goal: snapshot.goal))
    }

    /// The pets to show at `now`, at 0 steps once their day has ended.
    static func pets(_ snapshot: WatchGlanceSnapshot?, now: Date) -> PetsGlance {
        guard let snapshot else { return .placeholder }
        guard !snapshot.pets.isEmpty else { return .noPets }
        guard now >= snapshot.petsUntil else { return .pets(snapshot.pets) }
        return .pets(snapshot.pets.map { pet in
            var reset = pet
            reset.steps = 0
            return reset
        })
    }

    /// The timeline's entries: now, and each day end still ahead, so the
    /// day rolls over on the watch without a push.
    static func entryDates(_ snapshot: WatchGlanceSnapshot?, now: Date) -> [Date] {
        guard let snapshot else { return [now] }
        let ahead = Set([snapshot.stepsUntil, snapshot.petsUntil].filter { $0 > now })
        return [now] + ahead.sorted()
    }

    /// "6,240" in the person's locale.
    static func count(_ value: Int, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale))
    }

    /// "6.2K" for a small round complication.
    static func compactCount(_ value: Int, locale: Locale = .current) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...2)).locale(locale))
    }

    /// "6,240 of 10,000 steps", or "10,400 steps, goal reached".
    static func inline(_ steps: Steps, locale: Locale = .current) -> String {
        steps.reached
            ? "\(count(steps.steps, locale: locale)) steps, goal reached"
            : "\(count(steps.steps, locale: locale)) of \(count(steps.goal, locale: locale)) steps"
    }

    /// The rectangular line under the count: "62% of 10,000" or "Goal reached".
    static func progressLine(_ steps: Steps, locale: Locale = .current) -> String {
        steps.reached ? "Goal reached" : "\(steps.percent)% of \(count(steps.goal, locale: locale))"
    }
}

// MARK: - Widget kinds and the launcher's link

nonisolated enum WatchWidgetKind {
    static let steps = "WockettWatchSteps"
    static let pets = "WockettWatchPets"
    static let start = "WockettWatchStart"
}

/// The Start launcher opens the Watch app with this link; the app shows its
/// idle picker (or the live screen while a session runs). It starts nothing.
nonisolated enum WatchWidgetLink {
    static let scheme = "wockettwatch"
    static let startHost = "start"

    static var start: URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = startHost
        return parts.url
    }

    static func isStart(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == startHost
    }
}
