import Foundation

// MARK: - Notification status copy (fix/notification-status-explained, 2026-10-28)
//
// Settings showed a status chip above five reminder switches, and the switches
// keep their on position whatever iOS allows. With notifications off or never
// allowed, a switch that reads "on" looked like a reminder that would arrive.
// The line under the chip says what will actually happen. The strings live
// here so the tests can pin each state.

enum NotificationStatusText {

    /// The chip beside "Status". Provisional delivery does arrive, in
    /// Notification Center without a banner or sound, so the quiet state is
    /// "Quiet delivery" (it read "Quiet — no alerts" until 2026-10-28).
    static func chip(authorized: Bool, quiet: Bool) -> String {
        authorized ? "Enabled" : quiet ? "Quiet delivery" : "Disabled"
    }

    /// The line under the chip, or nil when everything is delivered normally.
    /// `authorized` wins over the others, as on the chip; "not asked yet" is
    /// none of the three.
    static func explanation(authorized: Bool, quiet: Bool, denied: Bool) -> String? {
        if authorized { return nil }
        if quiet { return "Reminders arrive quietly in Notification Center, without banners or sounds." }
        if denied {
            return "Notifications are off for Wockett in iOS Settings. Your choices below are saved, "
                + "but nothing will be delivered until you turn them on."
        }
        return "Reminders can't arrive until you allow notifications. Your choices below are saved."
    }
}
