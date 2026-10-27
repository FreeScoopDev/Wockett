import Testing
import Foundation
@testable import PoCSquat

/// "This week" is the locale's calendar week and "Last 7 days" is today plus
/// the six calendar days before it (2026-10-27, spec
/// fix/shared-week-windows). Every expectation below is a date written by
/// hand from the fixture, never one computed by the function under test.
/// Calendars are fixed (UTC, or New York for the DST case) because CI runs
/// in UTC and the simulator in whatever zone the Mac is in.
@MainActor
struct SharedWeekWindowsTests {

    // MARK: Fixture

    private static func calendar(firstWeekday: Int, zone: String = "UTC") -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 0) ?? .current
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.firstWeekday = firstWeekday
        return cal
    }

    private let sundayFirst = Self.calendar(firstWeekday: 1)
    private let mondayFirst = Self.calendar(firstWeekday: 2)

    /// A wall-clock time in `cal`'s zone.
    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
                    in cal: Calendar) throws -> Date {
        try #require(cal.date(from: DateComponents(year: year, month: month, day: day,
                                                   hour: hour, minute: minute)))
    }

    private func walk(at date: Date, pet: UUID, steps: Int = 3_000) -> WalkSession {
        WalkSession(id: UUID(), routeName: "Walk", date: date, elapsedTime: 1_800, totalDistance: 2_000,
                    waypoints: [], lapCount: 1, isLoop: false, activePetIds: [pet],
                    petDistances: [pet: 2_000], steps: steps)
    }

    // MARK: last7Days

    @Test("Last 7 days on a Wednesday: the Thursday before through that Wednesday, inclusive")
    func last7DaysOnAWednesday() throws {
        let cal = sundayFirst
        let now = try at(2026, 10, 28, 15, 30, in: cal)              // Wednesday afternoon
        let window = InsightsSummary.last7Days(now: now, calendar: cal)
        #expect(window.start == (try at(2026, 10, 22, in: cal)))    // Thursday 00:00
        #expect(window.end == (try at(2026, 10, 29, in: cal)))      // Thursday 00:00, exclusive
    }

    @Test("Last 7 days on the first of a month reaches back into the month before")
    func last7DaysCrossesAMonth() throws {
        let cal = sundayFirst
        let now = try at(2026, 11, 1, 9, in: cal)
        let window = InsightsSummary.last7Days(now: now, calendar: cal)
        #expect(window.start == (try at(2026, 10, 26, in: cal)))
        #expect(window.end == (try at(2026, 11, 2, in: cal)))
    }

    @Test("Across the US spring-forward change, last 7 days is 7 calendar days, not 168 hours")
    func last7DaysAcrossDST() throws {
        let cal = Self.calendar(firstWeekday: 1, zone: "America/New_York")
        let now = try at(2026, 3, 11, 12, in: cal)                  // DST began Sunday 2026-03-08
        let window = InsightsSummary.last7Days(now: now, calendar: cal)
        #expect(window.start == (try at(2026, 3, 5, in: cal)))      // local midnight, EST
        #expect(window.end == (try at(2026, 3, 12, in: cal)))       // local midnight, EDT
        #expect(window.duration == 7 * 86_400 - 3_600, "the lost hour is inside the window")
    }

    // MARK: calendarWeek

    @Test("The calendar week starts on the calendar's first weekday: Sunday and Monday differ")
    func calendarWeekFollowsFirstWeekday() throws {
        let sunday = try at(2026, 10, 25, 12, in: sundayFirst)       // the same instant in both
        let sun = InsightsSummary.calendarWeek(containing: sunday, calendar: sundayFirst)
        let mon = InsightsSummary.calendarWeek(containing: sunday, calendar: mondayFirst)
        #expect(sun.start == (try at(2026, 10, 25, in: sundayFirst)))
        #expect(sun.end == (try at(2026, 11, 1, in: sundayFirst)))
        #expect(mon.start == (try at(2026, 10, 19, in: mondayFirst)))
        #expect(mon.end == (try at(2026, 10, 26, in: mondayFirst)))
    }

    @Test("A session exactly at a window's start is inside it; exactly at its end is outside")
    func boundaries() throws {
        let cal = sundayFirst
        let now = try at(2026, 10, 30, 18, in: cal)
        let week = InsightsSummary.calendarWeek(containing: now, calendar: cal)
        let start = try at(2026, 10, 25, in: cal)
        let end = try at(2026, 11, 1, in: cal)
        let farFuture = try at(2027, 1, 1, in: cal)
        #expect(InsightsSummary.counts(start, in: week, now: farFuture))
        #expect(!InsightsSummary.counts(end, in: week, now: farFuture))
        #expect(!InsightsSummary.counts(start.addingTimeInterval(-1), in: week, now: farFuture))
    }

    @Test("A session after now never counts, even inside the window")
    func capsAtNow() throws {
        let cal = sundayFirst
        let pet = UUID()
        let now = try at(2026, 10, 30, 18, in: cal)
        let later = walk(at: try at(2026, 10, 30, 19, in: cal), pet: pet)
        let earlier = walk(at: try at(2026, 10, 30, 17, in: cal), pet: pet)
        let week = InsightsSummary.calendarWeek(containing: now, calendar: cal)
        #expect(PetStore.sessions(pet, in: [later, earlier], during: week, now: now).map(\.id) == [earlier.id])
        let last7 = InsightsSummary.last7Days(now: now, calendar: cal)
        #expect(PetStore.sessions(pet, in: [later, earlier], during: last7, now: now).map(\.id) == [earlier.id])
    }

    // MARK: One fixture, every surface

    /// Walks on Saturday 24 Oct, Monday 26, Wednesday 28 and Friday 30, and
    /// it is Friday evening. The week (Sunday 25 to Saturday 31) holds Mon,
    /// Wed and Fri: 3. The last 7 days (Saturday 24 to Friday 30) hold all 4.
    @Test("Insights week, pet 'Walks this week' and pet 'Last 7 days': 3, 3 and 4")
    func surfacesAgree() throws {
        let cal = sundayFirst
        let pet = UUID()
        let now = try at(2026, 10, 30, 18, in: cal)
        let sessions = try [
            walk(at: at(2026, 10, 24, 9, in: cal), pet: pet),   // prior Saturday
            walk(at: at(2026, 10, 26, 9, in: cal), pet: pet),   // Monday
            walk(at: at(2026, 10, 28, 9, in: cal), pet: pet),   // Wednesday
            walk(at: at(2026, 10, 30, 9, in: cal), pet: pet)    // Friday (today)
        ]

        let insights = InsightsSummary.comparison(sessions, period: .week, now: now, calendar: cal).current
        let week = InsightsSummary.calendarWeek(containing: now, calendar: cal)
        let tile = PetStore.sessions(pet, in: sessions, during: week, now: now)
        let last7 = PetStore.sessions(pet, in: sessions,
                                      during: InsightsSummary.last7Days(now: now, calendar: cal), now: now)
        #expect(insights.sessions == 3)
        #expect(tile.count == 3)
        #expect(last7.count == 4)
        #expect(insights.steps == 9_000, "3 walks of 3,000 steps")
    }

    // MARK: Week strip

    private func strip(weekOffset: Int, now: Date, calendar: Calendar,
                       sessions: [WalkSession] = []) async -> [CalendarDay] {
        let goalsKey = StepManager.UDKey.historicalDayGoals
        let savedGoals = UserDefaults.standard.object(forKey: goalsKey)
        defer {
            if let savedGoals { UserDefaults.standard.set(savedGoals, forKey: goalsKey) }
            else { UserDefaults.standard.removeObject(forKey: goalsKey) }
        }
        let manager = StepManager()
        manager.trackingMode = .appOnly
        manager.todaySteps = 4_321
        await manager.refreshWeeklyCalendar(sessions: sessions, weekOffset: weekOffset, now: now, calendar: calendar)
        return manager.weeklyCalendar
    }

    private func days(from year: Int, _ month: Int, _ day: Int, in cal: Calendar) throws -> [Date] {
        let first = try at(year, month, day, in: cal)
        return try (0..<7).map { try #require(cal.date(byAdding: .day, value: $0, to: first)) }
    }

    @Test("The week strip is the calendar week, and moves by whole calendar weeks")
    func stripIsTheCalendarWeek() async throws {
        let cal = sundayFirst
        // Thursday: on a Wednesday a Sunday-first week and "three days
        // either side" are the same seven days, so the old strip would pass.
        let now = try at(2026, 10, 29, 12, in: cal)
        let this = await strip(weekOffset: 0, now: now, calendar: cal)
        let last = await strip(weekOffset: -1, now: now, calendar: cal)
        let next = await strip(weekOffset: 1, now: now, calendar: cal)

        #expect(this.map(\.date) == (try days(from: 2026, 10, 25, in: cal)))   // Sun 25 … Sat 31
        #expect(last.map(\.date) == (try days(from: 2026, 10, 18, in: cal)))   // Sun 18 … Sat 24
        #expect(next.map(\.date) == (try days(from: 2026, 11, 1, in: cal)))    // Sun 1 … Sat 7

        // Sun–Wed past (App Only, no sessions: 0), Thu is today, Fri–Sat to come.
        #expect(this.map(\.steps) == [0, 0, 0, 0, 4_321, nil, nil])
        #expect(last.allSatisfy { $0.steps == 0 })
        #expect(next.allSatisfy { $0.steps == nil })

        // The Health header's range names the same week.
        let header = StepManager.stripWeek(weekOffset: 0, now: now, calendar: cal)
        #expect(header.start == this.first?.date)
    }

    @Test("A Monday-first calendar gives a Monday-to-Sunday strip")
    func stripMondayFirst() async throws {
        let cal = mondayFirst
        let now = try at(2026, 10, 28, 12, in: cal)
        let this = await strip(weekOffset: 0, now: now, calendar: cal)
        #expect(this.map(\.date) == (try days(from: 2026, 10, 26, in: cal)))   // Mon 26 … Sun 1
    }

    @Test("Early in the week the strip is today plus six days to come")
    func stripOnTheFirstDay() async throws {
        let cal = sundayFirst
        let now = try at(2026, 10, 25, 8, in: cal)                  // Sunday
        let this = await strip(weekOffset: 0, now: now, calendar: cal)
        #expect(this.map(\.date) == (try days(from: 2026, 10, 25, in: cal)))
        #expect(this.map(\.steps) == [4_321, nil, nil, nil, nil, nil, nil])
    }

    @Test("Across spring-forward the strip is still seven local midnights")
    func stripAcrossDST() async throws {
        let cal = Self.calendar(firstWeekday: 1, zone: "America/New_York")
        let now = try at(2026, 3, 12, 12, in: cal)                  // Thursday after the change
        let this = await strip(weekOffset: 0, now: now, calendar: cal)
        #expect(this.map(\.date) == (try days(from: 2026, 3, 8, in: cal)))      // Sun 8 … Sat 14
        #expect(this.allSatisfy { cal.component(.hour, from: $0.date) == 0 })
    }

    // MARK: Community crew

    @Test("The crew card's last 7 days: start of six days ago in, a week ago and later today out")
    func crewLast7Days() throws {
        let cal = sundayFirst
        let pet = UUID(), other = UUID()
        let now = try at(2026, 10, 28, 12, in: cal)                  // Wednesday noon
        func together(_ date: Date) -> WalkSession {
            WalkSession(id: UUID(), routeName: "Walk", date: date, elapsedTime: 1_800, totalDistance: 1_000,
                        waypoints: [], lapCount: 1, isLoop: false,
                        activePetIds: [pet, other], petDistances: [pet: 1_000, other: 1_000])
        }
        let sessions = try [
            together(at(2026, 10, 22, 0, 0, in: cal)),    // Thursday 00:00, first instant: in
            together(at(2026, 10, 21, 23, 59, in: cal)),  // the Wednesday before: out
            together(at(2026, 10, 28, 11, in: cal)),      // today, before now: in
            together(at(2026, 10, 28, 13, in: cal))       // today, after now: out
        ]
        let crew = CommunityHubSummary.crewWeek(pets: [(pet, "Nala")], sessions: sessions, now: now, calendar: cal)
        let nala = try #require(crew.first)
        #expect(nala.walks == 2 && nala.meters == 2_000)
        #expect(nala.daily == [1_000, 0, 0, 0, 0, 0, 1_000])
        #expect(CommunityHubSummary.walksTogether(petIDs: [pet, other], sessions: sessions,
                                                  now: now, calendar: cal) == 2)
    }

    // MARK: Range label

    @Test("The range label shows the last day inside the window, not the exclusive end")
    func rangeLabel() throws {
        var cal = sundayFirst
        cal.locale = Locale(identifier: "en_US")
        let week = DateInterval(start: try at(2026, 10, 25, in: cal), end: try at(2026, 11, 1, in: cal))
        let label = InsightsSummary.rangeLabel(week, calendar: cal)
        #expect(label.contains("Oct 25"))
        #expect(label.contains("31"))
        #expect(!label.contains("Nov"), "Nov 1 is the exclusive end: \(label)")
    }
}
