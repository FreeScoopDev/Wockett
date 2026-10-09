import Testing
import Foundation
@testable import PoCSquat

/// Health → Insights (2026-10-09). Every case fixes `now` and the calendar's
/// time zone and first weekday: CI runs in UTC, and a test that leaned on the
/// machine's clock lost a day there before (CommunityHubSummaryTests).
@MainActor
struct InsightsTests {

    /// US calendar: weeks start on Sunday. New York, so "today" is not UTC's.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.firstWeekday = 1
        return c
    }

    /// Thursday 15 October 2026, noon in New York.
    private var now: Date { date(2026, 10, 15, hour: 12) }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func session(_ when: Date, meters: Double, minutes: Double = 30, steps: Int = 0,
                         activity: String = "walking", pets: [UUID: Double] = [:],
                         flagged: Bool = false) -> WalkSession {
        var s = WalkSession(id: UUID(), routeName: "Walk", date: when, elapsedTime: minutes * 60,
                            totalDistance: meters, waypoints: [], lapCount: 0, isLoop: false,
                            activityType: activity, petDistances: pets, steps: steps)
        s.flaggedPossibleVehicle = flagged
        return s
    }

    @Test("The week is the calendar's week: Sunday to Sunday in the US, Monday where the locale says so")
    func weekFollowsTheCalendar() {
        let us = InsightsSummary.interval(.week, containing: now, calendar: calendar)
        #expect(us.start == date(2026, 10, 11, hour: 0))
        var monday = calendar
        monday.firstWeekday = 2
        #expect(InsightsSummary.interval(.week, containing: now, calendar: monday).start == date(2026, 10, 12, hour: 0))
    }

    @Test("This week so far is compared with the same stretch of last week, not all of it")
    func comparesLikeForLike() {
        let sessions = [
            session(date(2026, 10, 12), meters: 2_000),            // this Monday
            session(date(2026, 10, 15, hour: 8), meters: 1_000),   // this Thursday morning
            session(date(2026, 10, 5), meters: 1_500),             // last Monday: same stretch
            session(date(2026, 10, 9), meters: 9_000)              // last Friday: after the stretch
        ]
        let c = InsightsSummary.comparison(sessions, period: .week, now: now, calendar: calendar)
        #expect(c.current.distanceMeters == 3_000)
        #expect(c.previous.distanceMeters == 1_500, "last Friday is past the same point in the week")
        #expect(InsightsSummary.change(current: c.current.distanceMeters, previous: c.previous.distanceMeters) == 1.0)
        #expect(InsightsText.change(current: 3_000, previous: 1_500, period: .week) == "Up 100% vs last week")
    }

    @Test("No change is claimed when there is nothing to compare with")
    func noChangeFromNothing() {
        #expect(InsightsSummary.change(current: 5_000, previous: 0) == nil)
        #expect(InsightsText.change(current: 5_000, previous: 0, period: .month) == "Nothing last month to compare")
        #expect(InsightsText.change(current: 0, previous: 0, period: .week) == "Nothing yet this week")
    }

    @Test("Totals count activities, time, steps (estimated before 1.7), active days and each activity")
    func totals() {
        let sessions = [
            session(date(2026, 10, 12), meters: 1_524, steps: 0),                    // pre-1.7: 2,000 estimated
            session(date(2026, 10, 12, hour: 18), meters: 3_000, steps: 3_500, activity: "running"),
            session(date(2026, 10, 14), meters: 10_000, minutes: 40, activity: "cycling")
        ]
        let t = InsightsSummary.totals(sessions, in: InsightsSummary.interval(.week, containing: now, calendar: calendar),
                                       calendar: calendar)
        #expect(t.sessions == 3)
        #expect(t.duration == 100 * 60)
        #expect(t.steps == 2_000 + 3_500 + Int(10_000 / 0.762))
        #expect(t.activeDays == 2)
        #expect(t.distanceByActivity == [.walking: 1_524, .running: 3_000, .cycling: 10_000])
    }

    @Test("A session flagged as possible driving is left out everywhere")
    func flaggedLeftOut() {
        let sessions = [session(date(2026, 10, 13), meters: 1_000),
                        session(date(2026, 10, 13, hour: 15), meters: 40_000, flagged: true)]
        let week = InsightsSummary.interval(.week, containing: now, calendar: calendar)
        #expect(InsightsSummary.totals(sessions, in: week, calendar: calendar).distanceMeters == 1_000)
        #expect(InsightsSummary.dailyBuckets(sessions, period: .week, now: now, calendar: calendar)
            .map(\.distanceMeters).reduce(0, +) == 1_000)
        #expect(InsightsSummary.counted([sessions[1]]).isEmpty)
    }

    @Test("The day chart has every day of the period, future days at zero")
    func dailyBucketsCoverThePeriod() {
        let sessions = [session(date(2026, 10, 15, hour: 7), meters: 800)]
        let week = InsightsSummary.dailyBuckets(sessions, period: .week, now: now, calendar: calendar)
        #expect(week.count == 7)
        #expect(week[4].distanceMeters == 800, "Thursday is index 4 in a Sunday week")
        #expect(week.filter { $0.distanceMeters > 0 }.count == 1)
        #expect(InsightsSummary.dailyBuckets(sessions, period: .month, now: now, calendar: calendar).count == 31)
    }

    @Test("The trend is the last N whole periods, oldest first, ending with this one")
    func trend() {
        let sessions = [session(date(2026, 8, 20), meters: 4_000),
                        session(date(2026, 10, 2), meters: 1_000),
                        session(date(2026, 10, 14), meters: 2_000)]
        let months = InsightsSummary.trend(sessions, period: .month, now: now, calendar: calendar, count: 3)
        #expect(months.map(\.distanceMeters) == [4_000, 0, 3_000])
        #expect(months.last?.start == date(2026, 10, 1, hour: 0))
        #expect(InsightsSummary.trend(sessions, period: .week, now: now, calendar: calendar, count: 8).count == 8)
    }

    @Test("Weekday averages use whole past weeks only, divided by the weeks there is history for")
    func weekdayAverages() {
        let saturdays = [session(date(2026, 10, 3), meters: 4_000),   // a Saturday, last week
                         session(date(2026, 9, 26), meters: 4_000),   // a Saturday, two weeks ago
                         session(date(2026, 10, 14), meters: 9_000)]  // this week: not counted
        // History since the week of 20 September: three whole weeks, so / 3.
        #expect(InsightsSummary.weekdayAverages(saturdays, now: now, calendar: calendar, weeks: 4) == [7: 8_000.0 / 3])
        // With older history, the window is the full 4 weeks, and the July walk is outside it.
        let longer = saturdays + [session(date(2026, 7, 1), meters: 1_000)]
        #expect(InsightsSummary.weekdayAverages(longer, now: now, calendar: calendar, weeks: 4) == [7: 2_000])
        // Only this week so far: nothing to average yet.
        #expect(InsightsSummary.weekdayAverages([saturdays[2]], now: now, calendar: calendar).isEmpty)
    }

    @Test("Time of day buckets: morning 5-11, afternoon 11-17, evening 17-21, night otherwise")
    func timeOfDay() {
        #expect(InsightsTimeOfDay(hour: 4) == .night)
        #expect(InsightsTimeOfDay(hour: 5) == .morning)
        #expect(InsightsTimeOfDay(hour: 11) == .afternoon)
        #expect(InsightsTimeOfDay(hour: 17) == .evening)
        #expect(InsightsTimeOfDay(hour: 21) == .night)
        let sessions = [session(date(2026, 10, 12, hour: 7), meters: 1),
                        session(date(2026, 10, 13, hour: 7), meters: 1),
                        session(date(2026, 10, 13, hour: 19), meters: 1)]
        let week = InsightsSummary.interval(.week, containing: now, calendar: calendar)
        #expect(InsightsSummary.timeOfDay(sessions, in: week, calendar: calendar) == [.morning: 2, .evening: 1])
    }

    @Test("Each pet's distance and walks, most walked first; older sessions fall back to who was along")
    func pets() {
        let rex = PetProfile(name: "Rex"), bo = PetProfile(name: "Bo"), idle = PetProfile(name: "Idle")
        var old = session(date(2026, 10, 12), meters: 1_000)
        old.activePetIds = [bo.id]                                                // pre-1.7: no per-pet distances
        let sessions = [session(date(2026, 10, 13), meters: 3_000, pets: [rex.id: 3_000, bo.id: 500]), old]
        let week = InsightsSummary.interval(.week, containing: now, calendar: calendar)
        let totals = InsightsSummary.pets(sessions, pets: [bo, rex, idle], in: week)
        #expect(totals.map(\.pet.name) == ["Rex", "Bo"], "Idle walked nowhere this week")
        #expect(totals[0].distanceMeters == 3_000 && totals[0].sessions == 1)
        #expect(totals[1].distanceMeters == 1_500 && totals[1].sessions == 2)
        #expect(totals[0].estimatedSteps == Int(3_000 / 0.762))
    }
}
