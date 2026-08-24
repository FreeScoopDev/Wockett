import EventKit
import SwiftUI

// MARK: - WalkSchedulerService
//
// Creates recurring calendar reminders for walk goals.
// Each scheduled walk becomes an EKEvent in the user's default calendar.

@MainActor
@Observable
final class WalkSchedulerService {
    static let shared = WalkSchedulerService()

    var authorizationStatus: EKAuthorizationStatus = .notDetermined
    var scheduledWalkEventIDs: [String] = []

    private let store = EKEventStore()
    private let udKey = "scheduledWalkEventIDs"

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        scheduledWalkEventIDs = UserDefaults.standard.stringArray(forKey: udKey) ?? []
    }

    // MARK: - Authorization

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestWriteOnlyAccessToEvents()
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            return granted
        } catch {
            return false
        }
    }

    // MARK: - Schedule a recurring walk

    /// Adds a repeating calendar event for a walk reminder.
    /// - Parameters:
    ///   - title: Event title, e.g. "Morning Walk"
    ///   - startDate: The first occurrence date/time
    ///   - durationMinutes: Estimated walk duration
    ///   - recurrenceRule: nil for a one-off, or a weekly/daily rule
    @discardableResult
    func scheduleWalk(
        title: String,
        startDate: Date,
        durationMinutes: Int = 30,
        recurrenceRule: EKRecurrenceRule? = nil
    ) async -> Bool {
        guard authorizationStatus == .fullAccess || authorizationStatus == .writeOnly else {
            let granted = await requestAccess()
            guard granted else { return false }
            return await scheduleWalk(title: title, startDate: startDate,
                                      durationMinutes: durationMinutes, recurrenceRule: recurrenceRule)
        }

        let event = EKEvent(eventStore: store)
        event.title     = title
        event.startDate = startDate
        event.endDate   = startDate.addingTimeInterval(TimeInterval(durationMinutes * 60))
        event.calendar  = store.defaultCalendarForNewEvents
        event.notes     = "Scheduled by Wockett"
        event.alarms    = [EKAlarm(relativeOffset: -600)] // 10-min reminder

        if let rule = recurrenceRule {
            event.recurrenceRules = [rule]
        }

        do {
            try store.save(event, span: .thisEvent, commit: true)
            scheduledWalkEventIDs.append(event.eventIdentifier)
            UserDefaults.standard.set(scheduledWalkEventIDs, forKey: udKey)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Convenience rules

    static func weeklyRule(on weekday: EKWeekday) -> EKRecurrenceRule {
        EKRecurrenceRule(
            recurrenceWith: .weekly,
            interval: 1,
            daysOfTheWeek: [EKRecurrenceDayOfWeek(weekday)],
            daysOfTheMonth: nil,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: nil
        )
    }

    static func dailyRule() -> EKRecurrenceRule {
        EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
    }

    // MARK: - Remove a scheduled walk

    func removeWalk(eventID: String) {
        guard let event = store.event(withIdentifier: eventID) else { return }
        try? store.remove(event, span: .futureEvents, commit: true)
        scheduledWalkEventIDs.removeAll { $0 == eventID }
        UserDefaults.standard.set(scheduledWalkEventIDs, forKey: udKey)
    }
}
