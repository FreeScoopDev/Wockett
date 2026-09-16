import EventKit
import SwiftUI

// MARK: - WalkSchedulerService
//
// Legacy. Versions 1.7–1.10 created walk reminders as EKEvents in the user's
// calendar. Since 2026-09-09 new reminders are local notifications owned by
// NotificationService (see WalkReminder). This class remains only so Settings
// can list and delete the events an earlier version created; it never adds one.
//
// Deleting needs *full* calendar access, and 1.7–1.10 only ever asked for
// write-only. Write-only lets an app add events but not read them, and
// `event(withIdentifier:)` is a read — under write-only it returns nil, and
// until 1.12 the delete button then dropped our record while the event stayed
// in the user's Calendar. So the first delete tap now asks for full access.
// The request is made here and nowhere else, at the moment the user asks for
// something, which is the same rule NotificationService follows.

/// The calendar-store seam, so the removal logic is testable without a real
/// `EKEventStore` and the permission dialog it brings.
protocol CalendarEventStoring: AnyObject {
    func requestFullAccessToEvents() async throws -> Bool
    /// Removes the event with this identifier and all its future occurrences.
    /// Returns false when no such event exists (already deleted in Calendar).
    func removeEvent(withIdentifier id: String) throws -> Bool
}

extension EKEventStore: CalendarEventStoring {
    func removeEvent(withIdentifier id: String) throws -> Bool {
        guard let event = event(withIdentifier: id) else { return false }
        try remove(event, span: .futureEvents, commit: true)
        return true
    }
}

/// What happened when the user asked to delete a legacy calendar reminder.
/// Settings uses this to decide whether the row goes and what to tell them.
enum LegacyReminderRemoval: Equatable {
    /// The event was found and removed from the calendar.
    case removed
    /// The calendar no longer had it — the user deleted it there already.
    case alreadyGone
    /// Full calendar access was refused or unavailable. Nothing was removed,
    /// and only iOS Settings can change that.
    case accessDenied
    /// EventKit threw while removing. The event may still be in Calendar.
    case failed
}

@MainActor
@Observable
final class WalkSchedulerService {
    static let shared = WalkSchedulerService()

    private(set) var scheduledWalkEventIDs: [String] = []

    private let store: CalendarEventStoring
    private let defaults: UserDefaults
    private let udKey = "scheduledWalkEventIDs"

    // Resolved inside the body rather than as default arguments: default
    // arguments are evaluated in a nonisolated context.
    init(store: CalendarEventStoring? = nil, defaults: UserDefaults? = nil) {
        self.store = store ?? EKEventStore()
        self.defaults = defaults ?? .standard
        scheduledWalkEventIDs = self.defaults.stringArray(forKey: udKey) ?? []
    }

    // MARK: - Remove a legacy calendar reminder

    /// Asks for full calendar access if needed, then removes the event.
    ///
    /// Our record of the event is dropped in every case except `accessDenied`:
    /// a row the user can never act on is a bug, but a row they can act on
    /// after granting access in iOS Settings is worth keeping.
    func removeWalk(eventID: String) async -> LegacyReminderRemoval {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        guard granted else { return .accessDenied }

        let result: LegacyReminderRemoval
        do {
            result = try store.removeEvent(withIdentifier: eventID) ? .removed : .alreadyGone
        } catch {
            result = .failed
        }
        forget(eventID)
        return result
    }

    private func forget(_ eventID: String) {
        scheduledWalkEventIDs.removeAll { $0 == eventID }
        defaults.set(scheduledWalkEventIDs, forKey: udKey)
    }
}
