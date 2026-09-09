import EventKit
import SwiftUI

// MARK: - WalkSchedulerService
//
// Legacy. Versions 1.7–1.10 created walk reminders as EKEvents in the user's
// calendar. Since 2026-09-09 new reminders are local notifications owned by
// NotificationService (see WalkReminder). This class remains only so Settings
// can list and delete the events an earlier version created; it never adds one.

@MainActor
@Observable
final class WalkSchedulerService {
    static let shared = WalkSchedulerService()

    private(set) var scheduledWalkEventIDs: [String] = []

    private let store = EKEventStore()
    private let udKey = "scheduledWalkEventIDs"

    private init() {
        scheduledWalkEventIDs = UserDefaults.standard.stringArray(forKey: udKey) ?? []
    }

    // MARK: - Remove a legacy calendar reminder

    func removeWalk(eventID: String) {
        if let event = store.event(withIdentifier: eventID) {
            try? store.remove(event, span: .futureEvents, commit: true)
        }
        // Drop our record even if the calendar no longer has the event — the user
        // may have deleted it there, and a row that can't be removed is a bug.
        scheduledWalkEventIDs.removeAll { $0 == eventID }
        UserDefaults.standard.set(scheduledWalkEventIDs, forKey: udKey)
    }
}
