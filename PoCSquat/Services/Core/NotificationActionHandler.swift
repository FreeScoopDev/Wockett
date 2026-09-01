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
}

enum NotificationAction {
    static let snooze10      = "SNOOZE_10"
    static let markDone      = "MARK_DONE"
    static let startWalk     = "START_WALK"
    static let dismiss       = "DISMISS"
}

// MARK: - Registration

extension UNUserNotificationCenter {
    static func registerActionCategories() {
        let snooze = UNNotificationAction(
            identifier: NotificationAction.snooze10,
            title: "Snooze 10 min",
            options: []
        )
        let markDone = UNNotificationAction(
            identifier: NotificationAction.markDone,
            title: "Done",
            options: [.destructive]
        )
        let startWalk = UNNotificationAction(
            identifier: NotificationAction.startWalk,
            title: "Open App",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: NotificationAction.dismiss,
            title: "Dismiss",
            options: []
        )

        let waterBreakCategory = UNNotificationCategory(
            identifier: NotificationCategory.waterBreak,
            actions: [snooze, markDone],
            intentIdentifiers: [],
            options: []
        )
        let streakCategory = UNNotificationCategory(
            identifier: NotificationCategory.streakNudge,
            actions: [startWalk, dismiss],
            intentIdentifiers: [],
            options: []
        )
        let petCategory = UNNotificationCategory(
            identifier: NotificationCategory.petNudge,
            actions: [startWalk, dismiss],
            intentIdentifiers: [],
            options: []
        )
        let hydrationCategory = UNNotificationCategory(
            identifier: NotificationCategory.hydration,
            actions: [markDone, dismiss],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            waterBreakCategory, streakCategory, petCategory, hydrationCategory
        ])
    }
}

// MARK: - App delegate notification handler

final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID    = response.actionIdentifier
        let notifID     = response.notification.request.identifier

        switch actionID {
        case NotificationAction.snooze10:
            // Re-schedule the same notification 10 minutes from now
            let content = response.notification.request.content.mutableCopy() as! UNMutableNotificationContent
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false)
            let req = UNNotificationRequest(identifier: "\(notifID)-snooze", content: content, trigger: trigger)
            Task { try? await center.add(req) }

        case NotificationAction.startWalk:
            // App is foregrounded by the .foreground option on the action; nothing extra needed
            break

        default:
            break
        }

        completionHandler()
    }

    // Show notifications even when the app is in the foreground (during a walk)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
