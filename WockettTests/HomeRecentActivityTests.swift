import Testing
import Foundation
import MapKit
@testable import PoCSquat

/// Home's Recent activity (spec fix/home-start-first, 2026-10-28): the newest
/// three sessions by date, pet-credit entries left out
/// (fix/home-recent-hide-pet-credit), worded as Activity History words them. Expected
/// orders and text are written by hand from the fixture. Dates are pinned to
/// en_US_POSIX in UTC, since CI runs in UTC and the simulator in the Mac's
/// zone; the time's space before AM/PM is ICU's narrow no-break space
/// (U+202F). Distances go through History's own formatter
/// (`MKDistanceFormatter.abbreviated`), which follows the device's units.
@MainActor
struct HomeRecentActivityTests {

    private let utc = TimeZone(secondsFromGMT: 0) ?? .current
    private let posix = Locale(identifier: "en_US_POSIX")

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))
            ?? Date(timeIntervalSince1970: 0)
    }

    private let nala = UUID()

    private func session(_ name: String, _ date: Date, type: String = "walking", meters: Double = 2_000,
                         seconds: TimeInterval = 1_800, notes: String = "", pets: [UUID] = [],
                         isHike: Bool = false) -> WalkSession {
        WalkSession(id: UUID(), routeName: name, date: date, elapsedTime: seconds, totalDistance: meters,
                    waypoints: [], lapCount: 1, isLoop: false, activePetIds: pets, activityType: type,
                    notes: notes, isHike: isHike)
    }

    private func recent(_ sessions: [WalkSession]) -> HomeRecentActivity {
        HomeRecentActivity(sessions: sessions, locale: posix, timeZone: utc)
    }

    private func names(_ recent: HomeRecentActivity) -> [String] { recent.rows.map(\.text.title) }

    // MARK: How many, which, in what order

    @Test func noSessionsMeansNoRows() {
        let none = recent([])
        #expect(none.isEmpty)
        #expect(none.rows.isEmpty)
    }

    @Test func oneSessionIsOneRowWordedAsHistoryWordsIt() {
        let walk = session("Morning Walk", at(28, 8, 5), meters: 2_000, seconds: 1_830, notes: "Windy")
        let only = recent([walk])
        #expect(!only.isEmpty)
        #expect(only.rows.count == 1)
        let row = only.rows[0]
        #expect(row.id == walk.id)
        #expect(row.session.id == walk.id)
        #expect(row.text.title == "Morning Walk")
        #expect(row.text.subtitle == "Walk · Oct 28, 2026 at 8:05\u{202F}AM")
        #expect(row.text.distance == MKDistanceFormatter.abbreviated.string(fromDistance: 2_000))
        #expect(row.text.time == "30m 30s")
        #expect(row.text.notes == "Windy")
        #expect(row.text.symbol == .walk)
    }

    @Test func threeSessionsAllShowNewestFirst() {
        let rows = recent([
            session("C", at(28, 9)),
            session("B", at(27, 9)),
            session("A", at(26, 9))
        ])
        #expect(names(rows) == ["C", "B", "A"])
    }

    /// Five stored, as the store holds them after Log a Past Walk: `add`
    /// put the last-week walk on top. Home shows the three newest by date.
    @Test func fiveSessionsShowTheThreeNewestByDate() {
        let rows = recent([
            session("Logged for last week", at(20, 9)),
            session("Today", at(28, 7)),
            session("Yesterday", at(27, 18)),
            session("Monday", at(26, 12)),
            session("Sunday", at(25, 10))
        ])
        #expect(names(rows) == ["Today", "Yesterday", "Monday"])
    }

    @Test func aSmallerLimitIsRespected() {
        let rows = HomeRecentActivity(sessions: [session("A", at(28, 9)), session("B", at(27, 9))],
                                      limit: 1, locale: posix, timeZone: utc)
        #expect(names(rows) == ["A"])
        #expect(HomeRecentActivity.limit == 3)
    }

    @Test func sameTimeKeepsTheStoresOrder() {
        let rows = recent([session("First", at(28, 9)), session("Second", at(28, 9)), session("Third", at(28, 9))])
        #expect(names(rows) == ["First", "Second", "Third"])
    }

    // MARK: Kinds History lists

    @Test func indoorWalkReadsAsIndoor() {
        let indoor = session("Indoor Walk", at(28, 18, 30), type: "stationary", meters: 1_200, seconds: 1_200)
        let row = recent([indoor]).rows[0]
        #expect(row.text.subtitle == "Indoor walk · Oct 28, 2026 at 6:30\u{202F}PM")
        #expect(row.text.symbol == .indoor)
        #expect(row.text.time == "20m 0s")
    }

    @Test func runRideAndHikeUseTheirWords() {
        let rows = recent([
            session("Café Run", at(28, 7), type: "running"),
            session("River Ride", at(27, 7), type: "cycling"),
            session("Umstead", at(26, 7), isHike: true)
        ]).rows
        #expect(rows.map(\.text.symbol) == [.run, .ride, .walk])
        #expect(rows[0].text.subtitle.hasPrefix("Run · "))
        #expect(rows[1].text.subtitle.hasPrefix("Ride · "))
        #expect(rows[2].text.subtitle.hasPrefix("Hike · "))
    }

    // MARK: Pet-credit entries (fix/home-recent-hide-pet-credit, 2026-10-28)

    private let rex = UUID()

    /// An indoor walk with Rex and Nala, as `StationaryWalkView` saves it: the
    /// walk, then one credit entry per pet (one pet, no time) at the same date,
    /// plus a run the evening before.
    private func indoorWalkWithTwoPetsAndAnEarlierRun() -> [WalkSession] {
        let walkTime = at(28, 18, 30)
        return [
            session("Indoor Walk", walkTime, type: "stationary", meters: 1_200, seconds: 1_200, pets: [rex, nala]),
            session("Rex's Indoor Walk", walkTime, type: "stationary", meters: 1_200, seconds: 0, pets: [rex]),
            session("Nala's Indoor Walk", walkTime, type: "stationary", meters: 1_200, seconds: 0, pets: [nala]),
            session("Evening Run", at(27, 19), type: "running", meters: 5_000, seconds: 1_800)
        ]
    }

    /// Acceptance 1: the credit entries take no row, so the run stays on Home.
    @Test func petCreditEntriesAreLeftOffHome() {
        let stored = indoorWalkWithTwoPetsAndAnEarlierRun()
        #expect(stored[1].isPetCreditEntry && stored[2].isPetCreditEntry, "fixture: two credit entries")
        #expect(!stored[0].isPetCreditEntry && !stored[3].isPetCreditEntry, "fixture: two real activities")
        #expect(names(recent(stored)) == ["Indoor Walk", "Evening Run"])
    }

    /// Acceptance 2: History, with its default (show everything) filter,
    /// still lists every one of them, credit entries included.
    @Test func historyStillListsPetCreditEntries() {
        let stored = indoorWalkWithTwoPetsAndAnEarlierRun()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let listed = HistoryScope.apply(HistoryFilter(), to: stored, now: at(28, 20), calendar: cal)
        #expect(listed.map(\.routeName) == ["Indoor Walk", "Rex's Indoor Walk", "Nala's Indoor Walk", "Evening Run"])
    }

    /// Acceptance 3: only credit entries stored means no section, as with no
    /// history at all.
    @Test func onlyPetCreditEntriesMeansNoSection() {
        let credit = session("Nala's Indoor Walk", at(28, 19), type: "stationary", meters: 800,
                             seconds: 0, pets: [nala])
        #expect(credit.isPetCreditEntry)
        let none = recent([credit])
        #expect(none.isEmpty)
        #expect(none.rows.isEmpty)
    }

    /// A walk with one pet and real time is not a credit entry and stays.
    @Test func aRealWalkWithOnePetIsListed() {
        let walk = session("Walk with Nala", at(28, 9), seconds: 1_200, pets: [nala])
        #expect(!walk.isPetCreditEntry)
        #expect(names(recent([walk])) == ["Walk with Nala"])
    }

    @Test func zeroDistanceRecordIsListed() {
        let still = session("Stood Still", at(28, 12), meters: 0, seconds: 60)
        let row = recent([still]).rows[0]
        #expect(row.text.title == "Stood Still")
        #expect(row.text.distance == MKDistanceFormatter.abbreviated.string(fromDistance: 0))
        #expect(row.text.time == "1m 0s")
    }
}
