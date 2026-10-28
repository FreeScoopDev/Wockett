import Testing
@testable import PoCSquat

/// The Notifications section's status chip and the line under it
/// (2026-10-28, spec fix/notification-status-explained). Every expected
/// string is written out by hand, so a changed or swapped string fails here.
struct NotificationStatusTextTests {

    @Test func enabledHasNoExplanation() {
        #expect(NotificationStatusText.explanation(authorized: true, quiet: false, denied: false) == nil)
        #expect(NotificationStatusText.chip(authorized: true, quiet: false) == "Enabled")
    }

    @Test func quietSaysWhereRemindersGo() {
        #expect(NotificationStatusText.explanation(authorized: false, quiet: true, denied: false)
                == "Reminders arrive quietly in Notification Center, without banners or sounds.")
        #expect(NotificationStatusText.chip(authorized: false, quiet: true) == "Quiet delivery")
    }

    @Test func deniedPointsAtIOSSettings() {
        #expect(NotificationStatusText.explanation(authorized: false, quiet: false, denied: true)
                == "Notifications are off for Wockett in iOS Settings. Your choices below are saved, but nothing will be delivered until you turn them on.")
        #expect(NotificationStatusText.chip(authorized: false, quiet: false) == "Disabled")
    }

    @Test func notAskedYetSaysChoicesAreSaved() {
        #expect(NotificationStatusText.explanation(authorized: false, quiet: false, denied: false)
                == "Reminders can't arrive until you allow notifications. Your choices below are saved.")
        #expect(NotificationStatusText.chip(authorized: false, quiet: false) == "Disabled")
    }
}
