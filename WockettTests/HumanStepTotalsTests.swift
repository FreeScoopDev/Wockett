import Testing
import Foundation
@testable import PoCSquat

/// Per-day and per-week step totals leave rides out (2026-10-27, A1b). A
/// ride's "steps" are only distance / 0.762 m: 20,000 m would be 26,246.
/// Expected values are worked out by hand from each fixture.
struct HumanStepTotalsTests {

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// Tuesday 2026-10-27 00:00 UTC.
    private static let tuesday = Date(timeIntervalSince1970: 1_793_059_200)

    private func session(_ activity: String, at date: Date, meters: Double = 2_000, steps: Int = 0) -> WalkSession {
        WalkSession(id: UUID(), routeName: "Test", date: date, elapsedTime: 1_800,
                    totalDistance: meters, waypoints: [], lapCount: 1, isLoop: false,
                    activityType: activity, steps: steps)
    }

    private func onTuesday(_ sessions: [WalkSession]) -> Int {
        ActivitySummaryContent.humanSteps(on: Self.tuesday, in: sessions, calendar: Self.utc)
    }

    private let tuesdayNoon = Date(timeIntervalSince1970: 1_793_059_200 + 43_200)

    // MARK: - humanSteps(on:in:calendar:)

    @Test("A day with a 5,000-step walk and a 20 km ride is 5,000 steps")
    func walkPlusRide() {
        #expect(onTuesday([session("walking", at: tuesdayNoon, steps: 5_000),
                           session("cycling", at: tuesdayNoon, meters: 20_000)]) == 5_000)
    }

    @Test("A ride-only day is 0 steps, saved count or not")
    func rideOnly() {
        #expect(onTuesday([session("cycling", at: tuesdayNoon, meters: 20_000)]) == 0)
        #expect(onTuesday([session("cycling", at: tuesdayNoon, meters: 10_000, steps: 4_000)]) == 0)
    }

    @Test("A session on another day is ignored")
    func otherDayIgnored() {
        let monday = tuesdayNoon.addingTimeInterval(-86_400)
        #expect(onTuesday([session("walking", at: monday, steps: 7_000),
                           session("walking", at: tuesdayNoon, steps: 1_000)]) == 1_000)
    }

    @Test("23:59 belongs to its own day, 00:00 to the next")
    func dayBoundary() {
        let lateTuesday = Self.tuesday.addingTimeInterval(86_400 - 60)
        let wednesdayMidnight = Self.tuesday.addingTimeInterval(86_400)
        let sessions = [session("walking", at: lateTuesday, steps: 2_000),
                        session("walking", at: wednesdayMidnight, steps: 3_000)]
        #expect(onTuesday(sessions) == 2_000)
        #expect(ActivitySummaryContent.humanSteps(on: wednesdayMidnight, in: sessions, calendar: Self.utc) == 3_000)
    }

    // MARK: - bestStepDay(in:calendar:) (Community "Best day", A1c)

    private let mondayNoon = Date(timeIntervalSince1970: 1_793_059_200 - 86_400 + 43_200)
    private let wednesdayNoon = Date(timeIntervalSince1970: 1_793_059_200 + 86_400 + 43_200)

    private func best(_ sessions: [WalkSession]) -> (day: Date, steps: Int)? {
        ActivitySummaryContent.bestStepDay(in: sessions, calendar: Self.utc)
    }

    @Test("A walk day beats a bigger ride day: the ride adds no steps")
    func bestDay_walkBeatsRide() throws {
        let result = try #require(best([session("walking", at: mondayNoon, steps: 5_000),
                                        session("cycling", at: tuesdayNoon, meters: 20_000)]))
        #expect(result.day == Self.tuesday.addingTimeInterval(-86_400))
        #expect(result.steps == 5_000)
    }

    @Test("A day with a walk and a ride counts only the walk")
    func bestDay_rideAddsNothingToItsDay() throws {
        let result = try #require(best([session("walking", at: mondayNoon, steps: 5_000),
                                        session("cycling", at: mondayNoon, meters: 20_000),
                                        session("walking", at: tuesdayNoon, steps: 6_000)]))
        #expect(result.day == Self.tuesday)
        #expect(result.steps == 6_000)
    }

    @Test("Rides only, saved count or not: no Best day")
    func bestDay_rideOnly() {
        #expect(best([session("cycling", at: mondayNoon, meters: 20_000),
                      session("cycling", at: tuesdayNoon, meters: 10_000, steps: 4_000)]) == nil)
    }

    @Test("No history: no Best day")
    func bestDay_empty() {
        #expect(best([]) == nil)
    }

    @Test("A tie goes to the most recent day, whatever the order")
    func bestDay_tieMostRecent() throws {
        let wednesday = Self.tuesday.addingTimeInterval(86_400)
        let forward = try #require(best([session("walking", at: mondayNoon, steps: 4_000),
                                         session("walking", at: wednesdayNoon, steps: 4_000)]))
        let backward = try #require(best([session("walking", at: wednesdayNoon, steps: 4_000),
                                          session("walking", at: mondayNoon, steps: 4_000)]))
        #expect(forward.day == wednesday)
        #expect(backward.day == wednesday)
        #expect(forward.steps == 4_000)
    }

    @Test("Walks at 23:59 and 00:01 count on separate days")
    func bestDay_dayBoundary() throws {
        let lateMonday = Self.tuesday.addingTimeInterval(-60)
        let earlyTuesday = Self.tuesday.addingTimeInterval(60)
        let result = try #require(best([session("walking", at: lateMonday, steps: 3_000),
                                        session("walking", at: earlyTuesday, steps: 2_000)]))
        #expect(result.day == Self.tuesday.addingTimeInterval(-86_400))
        #expect(result.steps == 3_000)
    }

    // MARK: - Weekly summary notification text

    @Test("The week's steps leave rides out; its distance keeps them")
    func weeklySummary_totals() {
        let week = [session("walking", at: tuesdayNoon, meters: 3_000, steps: 4_000),
                    session("cycling", at: tuesdayNoon, meters: 20_000),
                    session("cycling", at: tuesdayNoon, meters: 10_000, steps: 4_000)]
        let t = SquatCounterApp.weeklySummaryTotals(week)
        #expect(t.steps == 4_000)
        #expect(abs(t.km - 33.0) < 1e-9)
        #expect(SquatCounterApp.weeklySummaryTotals([session("cycling", at: tuesdayNoon, meters: 42_000)]).steps == 0)
    }

    @Test("A week with steps keeps its existing text")
    func weeklySummary_withSteps() {
        #expect(SquatCounterApp.weeklySummaryBody(steps: 12_000, km: 9.5, streak: 3)
                == "This week: 12,000 steps · 9.5 km · 3-day streak 🔥. Keep it up!")
        #expect(SquatCounterApp.weeklySummaryBody(steps: 12_000, km: 9.5, streak: 0)
                == "This week: 12,000 steps · 9.5 km. Keep it up!")
    }

    @Test("A ride-only week gives its distance, not 'a new week starts today'")
    func weeklySummary_rideOnlyWeek() {
        #expect(SquatCounterApp.weeklySummaryBody(steps: 0, km: 42, streak: 0)
                == "This week: 42.0 km. Keep it up!")
        #expect(SquatCounterApp.weeklySummaryBody(steps: 0, km: 42, streak: 3)
                == "This week: 42.0 km · 3-day streak 🔥. Keep it up!")
    }

    @Test("An empty week keeps the new-week text")
    func weeklySummary_emptyWeek() {
        #expect(SquatCounterApp.weeklySummaryBody(steps: 0, km: 0, streak: 0)
                == "A new week starts today — lace up and start strong! 💪")
    }
}
