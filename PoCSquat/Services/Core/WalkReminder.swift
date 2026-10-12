import Foundation
import UserNotifications

// MARK: - WalkReminder
//
// A walk reminder the user set up: from Settings (once / daily / weekly) or from
// a finished walk's "Schedule this route" sheet (once, tied to a route). Since
// 2026-09-09 these are local notifications, not calendar events; the calendar
// integration that shipped in 1.7 is kept only to delete what it created.

struct WalkReminder: Codable, Identifiable, Hashable, Sendable {
    enum Schedule: Codable, Hashable, Sendable {
        case once(Date)
        /// `weekday` uses `Calendar` numbering: 1 = Sunday … 7 = Saturday.
        case daily(hour: Int, minute: Int)
        case weekly(weekday: Int, hour: Int, minute: Int)
    }

    let id: UUID
    var title: String
    /// Set when the reminder came from a route. One reminder per route: adding
    /// another for the same route replaces it.
    var routeName: String?
    var schedule: Schedule

    init(id: UUID = UUID(), title: String, routeName: String? = nil, schedule: Schedule) {
        self.id = id
        self.title = title
        self.routeName = routeName
        self.schedule = schedule
    }

    // MARK: Trigger

    var repeats: Bool {
        if case .once = schedule { return false }
        return true
    }

    /// What `UNCalendarNotificationTrigger` matches on. A one-off matches the
    /// full date; daily matches the time; weekly adds the weekday.
    func dateComponents(calendar: Calendar = .current) -> DateComponents {
        switch schedule {
        case .once(let date):
            return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        case .daily(let hour, let minute):
            return DateComponents(hour: hour, minute: minute)
        case .weekly(let weekday, let hour, let minute):
            return DateComponents(hour: hour, minute: minute, weekday: weekday)
        }
    }

    var trigger: UNCalendarNotificationTrigger {
        UNCalendarNotificationTrigger(dateMatching: dateComponents(), repeats: repeats)
    }

    /// A one-off whose time has passed has nothing left to do.
    func isExpired(at now: Date) -> Bool {
        if case .once(let date) = schedule { return date < now }
        return false
    }

    // MARK: Copy

    var notificationTitle: String { "Time for your walk!" }

    var notificationBody: String {
        if let routeName { return "Your \(routeName) walk is scheduled — lace up!" }
        return "\(title) — lace up!"
    }

    /// Settings row subtitle: "Daily at 7:30 AM", "Every Monday at 7:30 AM",
    /// "Sep 12, 2026 at 6:00 PM".
    func scheduleSummary(calendar: Calendar = .current) -> String {
        func time(_ hour: Int, _ minute: Int) -> String {
            let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
            return date.formatted(date: .omitted, time: .shortened)
        }
        switch schedule {
        case .once(let date):
            return date.formatted(date: .abbreviated, time: .shortened)
        case .daily(let hour, let minute):
            return "Daily at \(time(hour, minute))"
        case .weekly(let weekday, let hour, let minute):
            let name = calendar.weekdaySymbols[max(0, min(6, weekday - 1))]
            return "Every \(name) at \(time(hour, minute))"
        }
    }
}

// MARK: - A future day's reminder
//
// Health's calendar offers "Remind me" on a future day. Until 2026-10-12 that
// added an item to the Reminders app, which needed full access to every
// reminder the user has, for one item. It is a walk reminder like any other
// now: a notification, listed and deletable in Settings.

extension WalkReminder {
    static let goalDayHour = 8

    /// Once, at 8:00 on that day.
    static func goalDay(_ date: Date, goal: Int, calendar: Calendar = .current) -> WalkReminder {
        let morning = calendar.date(bySettingHour: goalDayHour, minute: 0, second: 0, of: date) ?? date
        return WalkReminder(title: "Walk goal: \(goal.formatted()) steps", schedule: .once(morning))
    }

    /// Whether `reminders` already holds that day's reminder, so the sheet
    /// shows it as set instead of adding a second.
    static func hasGoalDayReminder(on date: Date, in reminders: [WalkReminder],
                                   calendar: Calendar = .current) -> Bool {
        guard let morning = calendar.date(bySettingHour: goalDayHour, minute: 0, second: 0, of: date) else { return false }
        return reminders.contains { reminder in
            guard reminder.routeName == nil, case .once(let when) = reminder.schedule else { return false }
            return when == morning
        }
    }
}
