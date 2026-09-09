import UserNotifications
import UIKit

// MARK: - Notification categories & actions
//
// Registered once at launch. Notification senders set categoryIdentifier to
// one of these constants so the system attaches the right action buttons.

enum NotificationCategory {
    static let waterBreak    = "WATER_BREAK"
    static let streakNudge   = "STREAK_NUDGE"
    static let petNudge      = "PET_NUDGE"
    static let hydration     = "HYDRATION"
    static let walkReminder  = "WALK_REMINDER"
    static let untrackedWalk = "UNTRACKED_WALK"
}

enum NotificationAction {
    static let snooze10      = "SNOOZE_10"
    static let markDone      = "MARK_DONE"
    static let startWalk     = "START_WALK"
    static let saveWalk      = "SAVE_WALK"
    static let dismiss       = "DISMISS"
}

// MARK: - App delegate notification handler
//
// Callbacks may arrive on any queue. Everything stateful lives on
// NotificationService (main actor); this class snapshots what is Sendable and
// hops. The completion handler is called synchronously, as iOS requires.

final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let id       = response.notification.request.identifier
        let snapshot = NotificationSnapshot(response.notification.request.content)
        Task { @MainActor in
            await NotificationService.shared.handle(actionIdentifier: actionID, notificationIdentifier: id, snapshot: snapshot)
        }
        completionHandler()
    }

    // In-session kinds still banner while the app is open; everything else goes
    // quietly to the list, so a Sunday recap never pops over the dashboard.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let inSession = notification.request.content.threadIdentifier == NotificationKind.sessionThread
        completionHandler(inSession ? [.banner, .sound] : [.list, .sound])
    }
}
