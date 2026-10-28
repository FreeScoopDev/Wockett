import Testing
import Foundation
import SwiftData
@testable import PoCSquat

/// Activity History's search and filters (spec fix/history-search-filter,
/// 2026-10-27). Every expected list below is written by hand from the
/// fixture, never computed by the code under test. Calendars are fixed (UTC)
/// and `now` is injected, because CI runs in UTC and the simulator in the
/// Mac's zone.
@MainActor
struct HistoryScopeTests {

    // MARK: Fixture

    private static func calendar(firstWeekday: Int) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.firstWeekday = firstWeekday
        return cal
    }

    private let sundayFirst = Self.calendar(firstWeekday: 1)
    private let mondayFirst = Self.calendar(firstWeekday: 2)

    private func at(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        sundayFirst.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))
            ?? Date(timeIntervalSince1970: 0)
    }

    /// Wednesday 28 October 2026, 15:30 UTC. Its Sunday-first week starts
    /// Sun 25 Oct, its Monday-first week Mon 26 Oct, its last 7 days Thu
    /// 22 Oct 00:00.
    private var now: Date { at(10, 28, 15, 30) }

    private let nala = UUID(), beef = UUID()

    private func session(_ name: String, _ date: Date, type: String = "walking", meters: Double,
                         seconds: TimeInterval, notes: String = "", pets: [UUID] = [],
                         petDistances: [UUID: Double] = [:], isHike: Bool = false) -> WalkSession {
        WalkSession(id: UUID(), routeName: name, date: date, elapsedTime: seconds, totalDistance: meters,
                    waypoints: [], lapCount: 1, isLoop: false, activePetIds: pets, activityType: type,
                    notes: notes, petDistances: petDistances, isHike: isHike)
    }

    // Newest first, as the store keeps them.
    private var later: WalkSession { session("Evening Loop", at(10, 28, 20), meters: 1_000, seconds: 600) }
    private var morning: WalkSession {
        session("Morning Walk", at(10, 28, 8), meters: 2_000, seconds: 1_800, pets: [nala], petDistances: [nala: 2_000])
    }
    private var cafeRun: WalkSession { session("Café Run", at(10, 27, 7), type: "running", meters: 5_000, seconds: 1_500) }
    private var ride: WalkSession {
        session("River Ride", at(10, 25, 10), type: "cycling", meters: 15_000, seconds: 3_000,
                pets: [nala, beef], petDistances: [nala: 0, beef: 15_000])
    }
    /// Legacy pet record: `activePetIds` and no `petDistances`.
    private var indoor: WalkSession {
        session("Indoor Walk", at(10, 23, 18), type: "stationary", meters: 1_200, seconds: 1_200, pets: [nala])
    }
    /// Inside `now` minus 168 hours (from 21 Oct 15:30) but before the
    /// calendar's last 7 days (from 22 Oct 00:00).
    private var hike: WalkSession {
        session("Ridge Trail", at(10, 21, 20), meters: 6_000, seconds: 7_200,
                notes: "Saw a HERON by the lake", isHike: true)
    }
    private var zero: WalkSession { session("Short", at(10, 2, 9), meters: 0, seconds: 30) }
    /// An unknown type reads as a walk, as `InsightsSummary.totals` reads it.
    private var september: WalkSession { session("September Stroll", at(9, 30, 12), type: "skating", meters: 3_000, seconds: 2_400) }

    private func fixture() -> [WalkSession] {
        [later, morning, cafeRun, ride, indoor, hike, zero, september]
    }

    private func names(_ filter: HistoryFilter, _ sessions: [WalkSession]? = nil,
                       calendar: Calendar? = nil) -> [String] {
        HistoryScope.apply(filter, to: sessions ?? fixture(), now: now, calendar: calendar ?? sundayFirst)
            .map(\.routeName)
    }

    private func filter(query: String = "", activity: ActivityMode? = nil,
                        period: HistoryFilter.Period = .allTime, pet: UUID? = nil) -> HistoryFilter {
        var f = HistoryFilter()
        f.query = query; f.activity = activity; f.period = period; f.petID = pet
        return f
    }

    private let everything = ["Evening Loop", "Morning Walk", "Café Run", "River Ride", "Indoor Walk",
                              "Ridge Trail", "Short", "September Stroll"]

    // MARK: Defaults

    @Test("The default filter shows every record, zero-distance included, in the store's order")
    func defaultsShowEverything() {
        #expect(names(HistoryFilter()) == everything)
        #expect(HistoryFilter().isActive == false)
        #expect(HistoryFilter().menuCount == 0)
    }

    // MARK: Query

    @Test("The query matches the route name, ignoring case")
    func queryMatchesName() {
        #expect(names(filter(query: "river")) == ["River Ride"])
        #expect(names(filter(query: "WALK")) == ["Morning Walk", "Indoor Walk"])
    }

    @Test("The query matches the note")
    func queryMatchesNotes() {
        #expect(names(filter(query: "heron")) == ["Ridge Trail"])
    }

    @Test("The query ignores accents both ways")
    func queryIgnoresDiacritics() {
        #expect(names(filter(query: "cafe")) == ["Café Run"])
        let plain = [session("Cafe Corner", at(10, 1), meters: 100, seconds: 60)]
        #expect(names(filter(query: "CAFÉ"), plain) == ["Cafe Corner"])
    }

    @Test("The query is trimmed, and whitespace alone is no search at all")
    func queryTrimmedAndBlankIgnored() {
        #expect(names(filter(query: "  café \n")) == ["Café Run"])
        #expect(names(filter(query: "   ")) == everything)
        #expect(filter(query: "   ").isActive == false)
    }

    @Test("A query that matches nothing shows nothing")
    func queryMatchesNothing() {
        #expect(names(filter(query: "zzz")).isEmpty)
    }

    // MARK: Activity

    @Test("Each activity filter keeps only its own type; an unknown type counts as a walk")
    func activityFilter() {
        #expect(names(filter(activity: .running)) == ["Café Run"])
        #expect(names(filter(activity: .cycling)) == ["River Ride"])
        #expect(names(filter(activity: .stationary)) == ["Indoor Walk"])
        #expect(names(filter(activity: .walking))
                == ["Evening Loop", "Morning Walk", "Ridge Trail", "Short", "September Stroll"])
    }

    // MARK: Period

    @Test("This week, Sunday first: from Sunday 00:00 up to now, nothing after now")
    func thisWeekSundayFirst() {
        #expect(names(filter(period: .thisWeek)) == ["Morning Walk", "Café Run", "River Ride"])
    }

    @Test("This week, Monday first: Sunday's ride belongs to last week")
    func thisWeekMondayFirst() {
        #expect(names(filter(period: .thisWeek), calendar: mondayFirst) == ["Morning Walk", "Café Run"])
    }

    @Test("This month: from the 1st up to now")
    func thisMonth() {
        #expect(names(filter(period: .thisMonth))
                == ["Morning Walk", "Café Run", "River Ride", "Indoor Walk", "Ridge Trail", "Short"])
    }

    @Test("Last 7 days is calendar days, not now minus 168 hours")
    func last7Days() {
        // The hike at 21 Oct 20:00 is within 168 hours of now but before
        // 22 Oct 00:00, the start of the six calendar days before today.
        #expect(names(filter(period: .last7Days)) == ["Morning Walk", "Café Run", "River Ride", "Indoor Walk"])
    }

    @Test("A window's start is in, the second before it is out, and nothing after now counts",
          arguments: [HistoryFilter.Period.thisWeek, .thisMonth, .last7Days])
    func periodBoundaries(period: HistoryFilter.Period) throws {
        let window = try #require(HistoryScope.interval(period, now: now, calendar: sundayFirst))
        let rows = [
            session("After now", now.addingTimeInterval(1), meters: 1, seconds: 1),
            session("At now", now, meters: 1, seconds: 1),
            session("At start", window.start, meters: 1, seconds: 1),
            session("Just before", window.start.addingTimeInterval(-1), meters: 1, seconds: 1)
        ]
        #expect(names(filter(period: period), rows) == ["At now", "At start"])
    }

    // A window's exclusive end is not tested through `apply`: every window
    // here contains `now`, so its end is always after `now`, and "not after
    // now" already excludes it. `InsightsSummary.counts` has its own tests.

    @Test("All time keeps everything, a record after now included")
    func allTimeKeepsEverything() {
        #expect(names(filter(period: .allTime)) == everything)
    }

    // MARK: Pet

    @Test("The pet filter reads petDistances, and the legacy activePetIds when there are none")
    func petFilter() {
        // Morning: petDistances; Indoor: legacy ids only; the ride lists Nala
        // in activePetIds but gave her 0 m, so she did not take part.
        #expect(names(filter(pet: nala)) == ["Morning Walk", "Indoor Walk"])
        #expect(names(filter(pet: beef)) == ["River Ride"])
        #expect(names(filter(pet: UUID())).isEmpty)
    }

    // MARK: Combinations

    @Test("Filters combine with AND")
    func combinations() {
        #expect(names(filter(activity: .walking, period: .thisMonth)) == ["Morning Walk", "Ridge Trail", "Short"])
        #expect(names(filter(query: "ridge", activity: .walking, period: .thisMonth)) == ["Ridge Trail"])
        #expect(names(filter(activity: .walking, pet: nala)) == ["Morning Walk"])
        #expect(names(filter(activity: .stationary, period: .thisWeek)).isEmpty)
        #expect(names(filter(query: "walk", period: .last7Days, pet: nala)) == ["Morning Walk", "Indoor Walk"])
    }

    // MARK: Totals and the page

    @Test("Totals are the hand sums of the visible rows, the zero-distance record included")
    func totalsMatchVisibleRows() {
        let rows = HistoryScope.apply(filter(period: .thisMonth), to: fixture(), now: now, calendar: sundayFirst)
        let totals = HistoryScope.totals(rows)
        // Morning 2000/1800, Café 5000/1500, Ride 15000/3000, Indoor 1200/1200,
        // Ridge 6000/7200, Short 0/30.
        #expect(totals.count == 6)
        #expect(totals.meters == 29_200)
        #expect(totals.seconds == 14_730)
    }

    @Test("The page's header follows the filter: same rows, same sums, named scope")
    func pageHeaderFollowsFilter() {
        let page = HistoryPage(filter: filter(activity: .running, period: .thisMonth), sessions: fixture(),
                               petName: nil, now: now, calendar: sundayFirst)
        #expect(page.rows.map(\.routeName) == ["Café Run"])
        #expect(page.totals == HistoryTotals(sessions: [cafeRun]))
        #expect(page.totals.count == 1)
        #expect(page.totals.meters == 5_000)
        #expect(page.totals.seconds == 1_500)
        #expect(page.thisWeek == 1)
        #expect(page.title == "This month · Run")
        #expect(page.state == .rows)

        let all = HistoryPage(filter: HistoryFilter(), sessions: fixture(), petName: nil, now: now, calendar: sundayFirst)
        #expect(all.title == "All activities")
        #expect(all.totals.count == 8)
        #expect(all.totals.meters == 33_200)
        // Sunday-first week up to now: Morning, Café, Ride. Not the later loop.
        #expect(all.thisWeek == 3)
    }

    @Test("No history and no match are different states")
    func emptyStates() {
        let empty = HistoryPage(filter: filter(query: "x"), sessions: [], petName: nil, now: now, calendar: sundayFirst)
        #expect(empty.state == .noHistory)
        let none = HistoryPage(filter: filter(query: "zzz"), sessions: fixture(), petName: nil, now: now, calendar: sundayFirst)
        #expect(none.state == .noMatch)
        #expect(none.rows.isEmpty)
        // Clear filters is a fresh filter: everything comes back.
        let cleared = HistoryPage(filter: HistoryFilter(), sessions: fixture(), petName: nil, now: now, calendar: sundayFirst)
        #expect(cleared.state == .rows)
        #expect(cleared.rows.map(\.routeName) == everything)
        #expect(cleared.title == "All activities")
    }

    @Test("The scope title names each filter in force")
    func scopeTitles() {
        #expect(HistoryFilter().scopeTitle(petName: nil) == "All activities")
        #expect(filter(query: "   ").scopeTitle(petName: nil) == "All activities")
        #expect(filter(period: .last7Days).scopeTitle(petName: nil) == "Last 7 days")
        #expect(filter(activity: .stationary).scopeTitle(petName: nil) == "Indoor walk")
        #expect(filter(query: " river ", activity: .cycling, period: .thisWeek, pet: nala)
                    .scopeTitle(petName: "Nala") == "This week · Ride · Nala · “river”")
    }

    @Test("The menu counts its own choices; Reset clears them and keeps the search")
    func menuCountAndReset() {
        var f = filter(query: "river", activity: .cycling, period: .thisWeek, pet: nala)
        #expect(f.menuCount == 3)
        #expect(f.accessibilityValue == "3 filters active")
        f.resetMenu()
        #expect(f.menuCount == 0)
        #expect(f.accessibilityValue == "No filters active")
        #expect(f.query == "river")
        #expect(f.isActive)
        #expect(filter(period: .thisMonth).accessibilityValue == "1 filter active")
    }

    @Test("Offsets become the ids of the rows at those offsets; offsets past the end are ignored")
    func idsAtOffsets() {
        let rows = [morning, cafeRun, ride]
        #expect(HistoryScope.ids(at: IndexSet([0, 2]), in: rows) == [rows[0].id, rows[2].id])
        #expect(HistoryScope.ids(at: IndexSet([5]), in: rows).isEmpty)
    }

    // MARK: Store deletes

    private struct DiskFull: Error {}

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

    private func storedIds(_ context: ModelContext) throws -> Set<UUID> {
        Set(try context.fetch(FetchDescriptor<WalkSessionRecord>()).map(\.id))
    }

    /// Five rows, newest first: walk, run, walk, run, walk.
    private func fiveRows() -> [WalkSession] {
        [session("A walk", at(10, 28, 9), meters: 1_000, seconds: 600),
         session("B run", at(10, 27, 9), type: "running", meters: 2_000, seconds: 600),
         session("C walk", at(10, 26, 9), meters: 3_000, seconds: 600),
         session("D run", at(10, 25, 9), type: "running", meters: 4_000, seconds: 600),
         session("E walk", at(10, 24, 9), meters: 5_000, seconds: 600)]
    }

    @Test("delete(ids:) removes exactly those walks, in memory and on disk")
    func deleteIdsRemovesExactlyThose() throws {
        let (store, context, _) = try history()
        let rows = fiveRows()
        #expect(store.addAll(rows))
        store.delete(ids: [rows[1].id, rows[4].id])
        #expect(store.sessions.map(\.routeName) == ["A walk", "C walk", "D run"])
        #expect(try storedIds(context) == [rows[0].id, rows[2].id, rows[3].id])
    }

    @Test("delete(ids:) with an id that is not stored changes and writes nothing")
    func deleteUnknownIdChangesNothing() throws {
        let (store, context, disk) = try history()
        let rows = fiveRows()
        #expect(store.addAll(rows))
        let writes = disk.writes
        store.delete(ids: [UUID()])
        store.delete(ids: [])
        #expect(store.sessions.map(\.id) == rows.map(\.id))
        #expect(try storedIds(context) == Set(rows.map(\.id)))
        #expect(disk.writes == writes, "nothing to delete, nothing written")
    }

    @Test("delete(ids:) whose write fails puts every walk back, and the deletion does not linger")
    func deleteIdsFailedWriteRestores() throws {
        let (store, context, disk) = try history()
        let rows = fiveRows()
        #expect(store.addAll(rows))
        disk.failing = true
        store.delete(ids: [rows[1].id, rows[3].id])
        #expect(store.sessions.map(\.id) == rows.map(\.id), "back where they were")
        disk.failing = false
        let next = session("F walk", at(10, 20), meters: 10, seconds: 10)
        #expect(store.add(next))
        let stored = try context.fetch(FetchDescriptor<WalkSessionRecord>()).map(\.id)
        #expect(stored.count == 6, "kept once, not doubled")
        #expect(Set(stored) == Set(rows.map(\.id) + [next.id]))
    }

    @Test("delete(at:) still deletes by offset into the whole list")
    func deleteAtStillWorks() throws {
        let (store, context, _) = try history()
        let rows = fiveRows()
        #expect(store.addAll(rows))
        store.delete(at: IndexSet(integer: 2))
        #expect(store.sessions.map(\.routeName) == ["A walk", "B run", "D run", "E walk"])
        #expect(try storedIds(context) == Set(rows.map(\.id)).subtracting([rows[2].id]))
    }

    @Test("Swipe-delete in a filtered list deletes the row swiped, and no other")
    func filteredDeleteDeletesTheVisibleRow() throws {
        let (store, context, _) = try history()
        let rows = fiveRows()
        #expect(store.addAll(rows))
        let before = HistoryPage(filter: filter(activity: .running), sessions: store.sessions,
                                 petName: nil, now: now, calendar: sundayFirst)
        #expect(before.rows.map(\.routeName) == ["B run", "D run"])
        #expect(before.totals.meters == 6_000)

        // The second visible row is "D run". Offset 1 in the whole list is
        // "B run": that is what the old offset delete would have removed.
        before.delete(IndexSet(integer: 1), from: store)

        #expect(store.sessions.map(\.routeName) == ["A walk", "B run", "C walk", "E walk"])
        #expect(try storedIds(context) == Set(rows.map(\.id)).subtracting([rows[3].id]))
        let after = HistoryPage(filter: filter(activity: .running), sessions: store.sessions,
                                petName: nil, now: now, calendar: sundayFirst)
        #expect(after.rows.map(\.routeName) == ["B run"])
        #expect(after.totals.count == 1)
        #expect(after.totals.meters == 2_000)
    }
}
