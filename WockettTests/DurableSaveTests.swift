import Testing
import Foundation
import SwiftData
@testable import PoCSquat

/// Walk History counts a change only once it is on disk (fix/durable-save,
/// 2026-10-27). Until then every write was `try? context.save()`: a write
/// that threw left the walk on screen as saved and nothing on disk.
///
/// These use an in-memory store whose write can be made to fail. They never
/// touch the crash checkpoint file; the tests that do are in
/// `SnapshotRestoreTests`, which is serialized for that file.
@MainActor
struct DurableSaveTests {

    private struct DiskFull: Error {}

    /// A write that fails while `failing` is on, then writes for real.
    private final class Disk {
        var failing = false
        var writes = 0
    }

    /// `cloudKitDatabase: .none` for the reason given in CustomRouteStoreTests.
    private func history() throws -> (WalkHistoryStore, ModelContext, Disk) {
        let config = ModelConfiguration(schema: AppModelContainer.schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppModelContainer.schema, configurations: config)
        let context = ModelContext(container)
        let disk = Disk()
        let store = WalkHistoryStore(context: context, persist: {
            disk.writes += 1
            if disk.failing { throw DiskFull() }
            try context.save()
        })
        return (store, context, disk)
    }

    private func walk(_ name: String, daysAgo: Double = 0) -> WalkSession {
        WalkSession(id: UUID(), routeName: name, date: Date().addingTimeInterval(-daysAgo * 86_400),
                    elapsedTime: 1800, totalDistance: 2000, waypoints: [], lapCount: 1, isLoop: false)
    }

    private func storedIds(_ context: ModelContext) throws -> Set<UUID> {
        Set(try context.fetch(FetchDescriptor<WalkSessionRecord>()).map(\.id))
    }

    // MARK: - add / addAll

    @Test func add_whenTheWriteFails_returnsFalse_andLeavesNothingBehind() throws {
        let (store, context, disk) = try history()
        let kept = walk("Kept", daysAgo: 1)
        #expect(store.add(kept))
        disk.failing = true

        let lost = walk("Lost")
        #expect(store.add(lost) == false)

        #expect(store.sessions.map(\.id) == [kept.id], "the screen does not show what the disk lacks")
        // A fetch includes the context's unsaved changes: the failed record
        // is gone from it, not just from disk.
        #expect(try storedIds(context) == [kept.id], "the failed record left the context")
        // The next write that works must not carry the failed walk with it.
        disk.failing = false
        try context.save()
        #expect(try storedIds(context) == [kept.id])
    }

    @Test func add_whenTheWriteWorks_returnsTrue_newestFirst() throws {
        let (store, context, _) = try history()
        let first = walk("First", daysAgo: 1), second = walk("Second")
        #expect(store.add(first))
        #expect(store.add(second))
        #expect(store.sessions.map(\.id) == [second.id, first.id])
        #expect(try storedIds(context) == [first.id, second.id])
    }

    @Test func addAll_whenTheWriteFails_savesNoneOfThem() throws {
        let (store, context, disk) = try history()
        disk.failing = true
        #expect(store.addAll([walk("A"), walk("B", daysAgo: 1)]) == false)
        #expect(store.sessions.isEmpty)
        disk.failing = false
        try context.save()
        #expect(try storedIds(context).isEmpty)
    }

    @Test func addAll_whenTheWriteWorks_savesThemAllNewestFirst() throws {
        let (store, _, disk) = try history()
        let older = walk("Older", daysAgo: 2), newer = walk("Newer")
        #expect(store.addAll([older, newer]))
        #expect(store.sessions.map(\.id) == [newer.id, older.id])
        #expect(disk.writes == 1, "one write for the lot")
    }

    // MARK: - Edits and deletes put the old state back

    @Test func updateNotes_whenTheWriteFails_keepsTheOldNotes() throws {
        let (store, context, disk) = try history()
        var w = walk("Notes")
        w.notes = "before"
        #expect(store.add(w))
        disk.failing = true
        store.updateNotes(id: w.id, notes: "after")
        #expect(store.sessions.first?.notes == "before")
        disk.failing = false
        try context.save()
        let record = try #require(try context.fetch(FetchDescriptor<WalkSessionRecord>()).first)
        #expect(record.notes == "before", "a later write does not carry the failed edit to disk")
    }

    @Test func updateActivityType_whenTheWriteFails_keepsTheOldType() throws {
        let (store, context, disk) = try history()
        let w = walk("Type")
        #expect(store.add(w))
        disk.failing = true
        store.updateActivityType(id: w.id, activityType: ActivityMode.cycling.rawValue)
        #expect(store.sessions.first?.activityType == ActivityMode.walking.rawValue)
        disk.failing = false
        try context.save()
        let record = try #require(try context.fetch(FetchDescriptor<WalkSessionRecord>()).first)
        #expect(record.activityType == ActivityMode.walking.rawValue)
    }

    @Test func updateCountsTowardRouteStats_whenTheWriteFails_keepsTheOldValue() throws {
        let (store, context, disk) = try history()
        let w = walk("Stats")
        #expect(store.add(w))
        disk.failing = true
        store.updateCountsTowardRouteStats(id: w.id, counts: false)
        #expect(store.sessions.first?.countsTowardRouteStats == true)
        disk.failing = false
        try context.save()
        let record = try #require(try context.fetch(FetchDescriptor<WalkSessionRecord>()).first)
        #expect(record.countsTowardRouteStats == true)
    }

    @Test func updates_whenTheWriteWorks_change() throws {
        let (store, context, _) = try history()
        let w = walk("Edit")
        #expect(store.add(w))
        store.updateNotes(id: w.id, notes: "new")
        store.updateActivityType(id: w.id, activityType: ActivityMode.running.rawValue)
        store.updateCountsTowardRouteStats(id: w.id, counts: false)
        let shown = try #require(store.sessions.first)
        #expect(shown.notes == "new")
        #expect(shown.activityType == ActivityMode.running.rawValue)
        #expect(shown.countsTowardRouteStats == false)
        let record = try #require(try context.fetch(FetchDescriptor<WalkSessionRecord>()).first)
        #expect(record.notes == "new")
        #expect(record.activityType == ActivityMode.running.rawValue)
        #expect(record.countsTowardRouteStats == false)
    }

    @Test func delete_whenTheWriteFails_keepsTheWalk_onScreenAndOnDisk() throws {
        let (store, context, disk) = try history()
        let newer = walk("Newer"), older = walk("Older", daysAgo: 1)
        #expect(store.add(older))
        #expect(store.add(newer))
        disk.failing = true
        store.delete(at: IndexSet(integer: 1))
        #expect(store.sessions.map(\.id) == [newer.id, older.id], "back where it was")
        // The deletion must not wait in the context for the next write.
        disk.failing = false
        #expect(store.add(walk("Next", daysAgo: 3)))
        #expect(try storedIds(context).isSuperset(of: [newer.id, older.id]))
    }

    @Test func delete_whenTheWriteWorks_removesIt() throws {
        let (store, context, _) = try history()
        let newer = walk("Newer"), older = walk("Older", daysAgo: 1)
        #expect(store.add(older))
        #expect(store.add(newer))
        store.delete(at: IndexSet(integer: 1))
        #expect(store.sessions.map(\.id) == [newer.id])
        #expect(try storedIds(context) == [newer.id])
    }

    // MARK: - Indoor walk

    @Test func indoorWalk_whenTheWriteFails_savesNeitherTheWalkNorThePetsCredit() throws {
        let (store, context, disk) = try history()
        disk.failing = true
        let indoor = walk("Indoor Walk")
        let credit = try #require(StationaryWalkManager.petCreditEntry(
            petId: UUID(), name: "Nala", sinceSteps: 0, currentSteps: 500, start: indoor.date))
        #expect(StationaryWalkView.saveIndoorWalk(indoor, petCredit: [credit], to: store) == nil)
        #expect(store.sessions.isEmpty)
        disk.failing = false
        try context.save()
        #expect(try storedIds(context).isEmpty)
    }

    @Test func indoorWalk_whenTheWriteWorks_savesBoth_walkOnTop() throws {
        let (store, _, _) = try history()
        let indoor = walk("Indoor Walk")
        let first = try #require(StationaryWalkManager.petCreditEntry(
            petId: UUID(), name: "Nala", sinceSteps: 0, currentSteps: 500, start: indoor.date))
        let second = try #require(StationaryWalkManager.petCreditEntry(
            petId: UUID(), name: "Beef", sinceSteps: 0, currentSteps: 500, start: indoor.date))
        #expect(StationaryWalkView.saveIndoorWalk(indoor, petCredit: [first, second], to: store) != nil)
        // As one `add` each left them: credit in turn, then the walk on top.
        #expect(store.sessions.map(\.id) == [indoor.id, second.id, first.id])
    }
}
