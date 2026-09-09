import Testing
import Foundation
import UserNotifications
@testable import PoCSquat

/// A recording fake for the UNUserNotificationCenter seam.
final class FakeNotificationCenter: NotificationCentering {
    var status: UNAuthorizationStatus
    var grant = true
    var added: [UNNotificationRequest] = []
    var removedPending: [[String]] = []
    var removedDelivered: [[String]] = []
    var authRequests: [UNAuthorizationOptions] = []
    var categories: Set<UNNotificationCategory> = []

    init(status: UNAuthorizationStatus = .authorized) { self.status = status }

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authRequests.append(options)
        if grant { status = options.contains(.provisional) ? .provisional : .authorized }
        return grant
    }
    func add(_ request: UNNotificationRequest) async throws { added.append(request) }
    func removePending(withIdentifiers ids: [String]) { removedPending.append(ids) }
    func removeDelivered(withIdentifiers ids: [String]) { removedDelivered.append(ids) }
    func pendingIdentifiers() async -> [String] { added.map(\.identifier) }
    func setCategories(_ categories: Set<UNNotificationCategory>) { self.categories = categories }
}

@MainActor
struct NotificationServiceTests {

    private func make(status: UNAuthorizationStatus = .authorized) -> (NotificationService, FakeNotificationCenter, UserDefaults) {
        let center = FakeNotificationCenter(status: status)
        let suite = "NotificationServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (NotificationService(center: center, defaults: defaults), center, defaults)
    }

    @Test func schedulesWithTheKindsStableIdentifier() async {
        let (svc, center, _) = make()
        let ok = await svc.schedule(.hydration, title: "t", body: "b", trigger: nil)
        #expect(ok)
        #expect(center.added.map(\.identifier) == ["hydration"])
    }

    @Test func schedulingReplacesAPendingCopyFirst() async {
        let (svc, center, _) = make()
        await svc.schedule(.streakNudge, title: "t", body: "b", trigger: nil)
        await svc.schedule(.streakNudge, title: "t2", body: "b2", trigger: nil)
        #expect(center.removedPending == [["streak-protection"], ["streak-protection"]])
        #expect(center.added.count == 2)
    }

    @Test func settingsToggleOffSkipsAndCancels() async {
        let (svc, center, defaults) = make()
        defaults.set(false, forKey: "notif_weeklySummary")
        let ok = await svc.schedule(.weeklySummary, title: "t", body: "b", trigger: nil)
        #expect(!ok)
        #expect(center.added.isEmpty)
        #expect(center.removedPending == [["wkt-weekly-summary"]])
    }

    @Test func deniedDoesNotDeliverButProvisionalDoes() async {
        let (denied, dc, _) = make(status: .denied)
        #expect(await denied.schedule(.petNudge, title: "t", body: "b", trigger: nil) == false)
        #expect(dc.added.isEmpty)

        let (quiet, qc, _) = make(status: .provisional)
        #expect(await quiet.schedule(.petNudge, title: "t", body: "b", trigger: nil) == true)
        #expect(qc.added.count == 1)
    }

    @Test func quietDeliveryIsRequestedOnlyWhenNeverAsked() async {
        let (fresh, fc, _) = make(status: .notDetermined)
        await fresh.requestQuietDeliveryIfNeverAsked()
        #expect(fc.authRequests.count == 1)
        #expect(fc.authRequests[0].contains(.provisional))
        #expect(fresh.authorizationStatus == .provisional)
        #expect(fresh.isDelivering)

        let (already, ac, _) = make(status: .authorized)
        await already.requestQuietDeliveryIfNeverAsked()
        #expect(ac.authRequests.isEmpty)
    }

    @Test func fullAuthorizationPromptsWithAlertAndSound() async {
        let (svc, center, _) = make(status: .provisional)
        let granted = await svc.requestFullAuthorization()
        #expect(granted)
        #expect(center.authRequests == [[.alert, .sound]])
        #expect(svc.isFullyAuthorized)
    }

    @Test func kindsCarryCategoryThreadAndLevel() async {
        let (svc, center, _) = make()
        await svc.schedule(.petNudge, title: "t", body: "b", trigger: nil)
        await svc.schedule(.weeklySummary, title: "t", body: "b", trigger: nil)
        let pet = center.added[0].content, weekly = center.added[1].content
        #expect(pet.categoryIdentifier == NotificationCategory.petNudge)
        #expect(pet.threadIdentifier == "wkt.nudges")
        #expect(pet.interruptionLevel == .active)
        #expect(weekly.interruptionLevel == .passive)
        #expect(weekly.threadIdentifier == "wkt.digest")
    }

    /// Every kind on the session thread is time-sensitive; nothing off it is.
    /// Driven through `schedule` so the level on the *request* is what is checked,
    /// not just the enum property.
    @Test func inWalkKindsAreTimeSensitiveAndNothingElseIs() async {
        let (svc, center, defaults) = make()
        defaults.set(true, forKey: "notif_hydration")
        let inWalk: [NotificationKind] = [.waterBreak(1), .checkpoint("50%"), .autoPause, .routeEvent("offRoute"), .hydration]
        let elsewhere: [NotificationKind] = [.streakNudge, .petNudge, .scheduledRoute("Loop")]
        for kind in inWalk + elsewhere {
            #expect(await svc.schedule(kind, title: "t", body: "b", trigger: nil), "\(kind) should schedule")
        }
        #expect(center.added.count == inWalk.count + elsewhere.count)
        for (kind, request) in zip(inWalk, center.added.prefix(inWalk.count)) {
            #expect(request.content.interruptionLevel == .timeSensitive, "\(kind)")
            #expect(request.content.threadIdentifier == NotificationKind.sessionThread, "\(kind)")
        }
        for (kind, request) in zip(elsewhere, center.added.suffix(elsewhere.count)) {
            #expect(request.content.interruptionLevel == .active, "\(kind)")
            #expect(request.content.threadIdentifier != NotificationKind.sessionThread, "\(kind)")
        }
    }

    @Test func cancelWaterBreaksRemovesTheWholeSeries() {
        let (svc, center, _) = make()
        svc.cancelWaterBreaks()
        #expect(center.removedPending == [(1...12).map { "waterBreak-\($0)" }])
    }

    @Test func snoozeReschedulesTenMinutesOutUnderASnoozeId() async {
        let (svc, center, _) = make()
        let content = UNMutableNotificationContent(); content.title = "Water break!"
        await svc.handle(actionIdentifier: NotificationAction.snooze10, notificationIdentifier: "waterBreak-3", snapshot: NotificationSnapshot(content))
        #expect(center.added.map(\.identifier) == ["waterBreak-3-snooze"])
        #expect(center.added[0].content.title == "Water break!")
        let trigger = center.added[0].trigger as? UNTimeIntervalNotificationTrigger
        #expect(trigger?.timeInterval == 600)
    }

    @Test func doneClearsDeliveredAndItsSnooze() async {
        let (svc, center, _) = make()
        await svc.handle(actionIdentifier: NotificationAction.markDone, notificationIdentifier: "hydration", snapshot: NotificationSnapshot(UNMutableNotificationContent()))
        #expect(center.removedDelivered == [["hydration"]])
        #expect(center.removedPending == [["hydration-snooze"]])
    }

    @Test func startWalkRecordsAnActionTheAppRootConsumesOnce() async {
        let (svc, _, _) = make()
        await svc.handle(actionIdentifier: NotificationAction.startWalk, notificationIdentifier: "streak-protection", snapshot: NotificationSnapshot(UNMutableNotificationContent()))
        #expect(svc.consumePendingAction() == NotificationAction.startWalk)
        #expect(svc.consumePendingAction() == nil)
    }

    @Test func registersAllFourCategories() {
        let (svc, center, _) = make()
        svc.registerCategories()
        #expect(center.categories.map(\.identifier).sorted() ==
                [NotificationCategory.hydration, NotificationCategory.petNudge,
                 NotificationCategory.streakNudge, NotificationCategory.waterBreak].sorted())
    }

    @Test func scheduledRouteReminderIsKeyedByRouteNameSoItCanBeReplaced() async {
        let (svc, center, _) = make()
        await svc.schedule(.scheduledRoute("Park Loop"), title: "t", body: "b", trigger: nil)
        await svc.schedule(.scheduledRoute("Park Loop"), title: "t", body: "b", trigger: nil)
        #expect(center.added.map(\.identifier) == ["scheduledRoute-Park Loop", "scheduledRoute-Park Loop"])
        #expect(center.removedPending.allSatisfy { $0 == ["scheduledRoute-Park Loop"] })
    }
}
