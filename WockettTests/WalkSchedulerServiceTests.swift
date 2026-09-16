import Testing
import Foundation
@testable import PoCSquat

/// A recording fake for the calendar-store seam.
final class FakeCalendarStore: CalendarEventStoring {
    var grant = true
    var requestThrows = false
    var existingIDs: Set<String>
    var removeThrows = false
    var accessRequests = 0
    var removed: [String] = []

    init(existing: Set<String> = []) { existingIDs = existing }

    struct Failure: Error {}

    func requestFullAccessToEvents() async throws -> Bool {
        accessRequests += 1
        if requestThrows { throw Failure() }
        return grant
    }

    func removeEvent(withIdentifier id: String) throws -> Bool {
        if removeThrows { throw Failure() }
        guard existingIDs.contains(id) else { return false }
        existingIDs.remove(id)
        removed.append(id)
        return true
    }
}

/// `WalkSchedulerService` exists only to delete the calendar events 1.7–1.10
/// created. Those versions asked for write-only access, under which an event
/// cannot be read back, so the delete silently did nothing while dropping the
/// row. These pin the 1.12 behaviour: ask for full access first, and keep the
/// row when access is the thing that failed.
@MainActor
struct WalkSchedulerServiceTests {

    private func make(existing: Set<String> = [], recorded: [String]) -> (WalkSchedulerService, FakeCalendarStore) {
        let store = FakeCalendarStore(existing: existing)
        let suite = "WalkSchedulerServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(recorded, forKey: "scheduledWalkEventIDs")
        return (WalkSchedulerService(store: store, defaults: defaults), store)
    }

    @Test("Loads the recorded event IDs from defaults")
    func loadsRecordedIDs() {
        let (svc, _) = make(recorded: ["a", "b"])
        #expect(svc.scheduledWalkEventIDs == ["a", "b"])
    }

    @Test("Asks for full calendar access before touching the event")
    func requestsFullAccessFirst() async {
        let (svc, store) = make(existing: ["a"], recorded: ["a"])
        _ = await svc.removeWalk(eventID: "a")
        #expect(store.accessRequests == 1)
    }

    @Test("Removes an event the calendar still has, and forgets it")
    func removesAndForgets() async {
        let (svc, store) = make(existing: ["a", "b"], recorded: ["a", "b"])
        let outcome = await svc.removeWalk(eventID: "a")
        #expect(outcome == .removed)
        #expect(store.removed == ["a"])
        #expect(svc.scheduledWalkEventIDs == ["b"])
    }

    @Test("An event the user already deleted in Calendar is reported gone and forgotten")
    func alreadyGoneIsForgotten() async {
        let (svc, store) = make(existing: [], recorded: ["a"])
        let outcome = await svc.removeWalk(eventID: "a")
        #expect(outcome == .alreadyGone)
        #expect(store.removed.isEmpty)
        #expect(svc.scheduledWalkEventIDs.isEmpty)
    }

    @Test("Denied access removes nothing and keeps the row so the user can retry")
    func deniedKeepsTheRow() async {
        let (svc, store) = make(existing: ["a"], recorded: ["a"])
        store.grant = false
        let outcome = await svc.removeWalk(eventID: "a")
        #expect(outcome == .accessDenied)
        #expect(store.removed.isEmpty)
        #expect(svc.scheduledWalkEventIDs == ["a"])
    }

    @Test("A throwing access request counts as denied")
    func throwingRequestIsDenied() async {
        let (svc, store) = make(existing: ["a"], recorded: ["a"])
        store.requestThrows = true
        let outcome = await svc.removeWalk(eventID: "a")
        #expect(outcome == .accessDenied)
        #expect(svc.scheduledWalkEventIDs == ["a"])
    }

    @Test("A failed removal is reported, and the row is dropped rather than left stuck")
    func failedRemovalIsReportedAndForgotten() async {
        let (svc, store) = make(existing: ["a"], recorded: ["a"])
        store.removeThrows = true
        let outcome = await svc.removeWalk(eventID: "a")
        #expect(outcome == .failed)
        #expect(svc.scheduledWalkEventIDs.isEmpty)
    }

    @Test("Forgetting persists to defaults")
    func forgettingPersists() async {
        let store = FakeCalendarStore(existing: ["a"])
        let suite = "WalkSchedulerServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["a", "b"], forKey: "scheduledWalkEventIDs")
        let svc = WalkSchedulerService(store: store, defaults: defaults)
        _ = await svc.removeWalk(eventID: "a")
        #expect(defaults.stringArray(forKey: "scheduledWalkEventIDs") == ["b"])
    }
}
