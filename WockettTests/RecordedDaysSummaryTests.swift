import Testing
import Foundation
@testable import PoCSquat

/// The Health tab's 30-day trend and the month calendar's stats are over
/// recorded days only, and say how many (2026-10-27, A3). Expected values are
/// worked out by hand from each fixture.
struct RecordedDaysSummaryTests {

    private typealias Day = RecordedDaysSummary.Day

    /// 30 days, goal 8,000. 18 have steps; 12 are 0 or have no value at all.
    /// Recorded steps, in order:
    ///   9,000  4,000  8,000  12,500  3,000  7,999  10,000  2,500  6,000
    ///   8,001  1,000  5,500  11,000  4,500  7,000  3,500  9,500  2,000
    /// Sum 115,000 (running total: 44,499 after the first six, 77,500 after
    /// twelve, 115,000 after all eighteen).
    /// At or above 8,000: 9,000, 8,000, 12,500, 10,000, 8,001, 11,000, 9,500 = 7.
    private static let recordedSteps = [9_000, 4_000, 8_000, 12_500, 3_000, 7_999, 10_000, 2_500, 6_000,
                                        8_001, 1_000, 5_500, 11_000, 4_500, 7_000, 3_500, 9_500, 2_000]
    private static let thirtyDays: [Day] = {
        var days: [Day] = []
        var recorded = recordedSteps.makeIterator()
        for i in 0..<30 {
            // Every fifth day (0, 5, …, 25) has no value; every other
            // non-recorded day is a measured 0. Neither counts.
            if i % 5 == 0 {
                days.append(Day(steps: nil, goal: 8_000))
            } else if i % 5 == 3 && i > 20 {
                days.append(Day(steps: 0, goal: 8_000))
            } else if let steps = recorded.next() {
                days.append(Day(steps: steps, goal: 8_000))
            } else {
                days.append(Day(steps: 0, goal: 8_000))
            }
        }
        return days
    }()

    @Test("The fixture has 18 days with steps out of 30, summing to 115,000")
    func sumIsHandChecked() {
        #expect(Self.thirtyDays.count == 30)
        #expect(Self.thirtyDays.compactMap(\.steps).filter { $0 > 0 }.count == 18)
        #expect(Self.recordedSteps.reduce(0, +) == 115_000)
    }

    @Test("30 days, 18 with steps: average, goals and best are over those 18")
    func thirtyDaysEighteenRecorded() {
        let s = RecordedDaysSummary.make(days: Self.thirtyDays)
        #expect(s.recordedDays == 18)
        #expect(s.totalDays == 30)
        #expect(s.totalSteps == 115_000)
        #expect(s.average == 6_388)          // 115,000 / 18 = 6,388.9, truncated
        #expect(s.goalsMet == 7)
        #expect(s.best == 12_500)
        #expect(!s.isEmpty)
        #expect(s.coverageText == "18 of 30 days have steps")
    }

    @Test("All-zero and empty input is empty: no average, no best, no goals")
    func emptyInput() {
        for days in [[], Array(repeating: Day(steps: 0, goal: 8_000), count: 30),
                     Array(repeating: Day(steps: nil, goal: 8_000), count: 30)] {
            let s = RecordedDaysSummary.make(days: days)
            #expect(s.isEmpty)
            #expect(s.recordedDays == 0)
            #expect(s.average == nil)
            #expect(s.best == nil)
            #expect(s.goalsMet == 0)
        }
    }

    @Test("A day exactly at its goal is met; one step below is not")
    func goalBoundary() {
        let s = RecordedDaysSummary.make(days: [Day(steps: 8_000, goal: 8_000), Day(steps: 7_999, goal: 8_000)])
        #expect(s.goalsMet == 1)
        #expect(s.recordedDays == 2)
        #expect(s.coverageText == "2 of 2 days have steps")
    }

    @Test("Each day is judged against its own goal (custom schedule)")
    func perDayGoals() {
        // 6,000 meets a 5,000 weekend goal; 9,000 misses a 10,000 weekday goal;
        // 7,000 meets 7,000. Against one 8,000 goal it would be 1 met, not 2.
        let s = RecordedDaysSummary.make(days: [Day(steps: 6_000, goal: 5_000),
                                                Day(steps: 9_000, goal: 10_000),
                                                Day(steps: 7_000, goal: 7_000)])
        #expect(s.goalsMet == 2)
        #expect(s.average == 7_333)
        #expect(s.best == 9_000)
    }

    @Test("Coverage reads naturally for one recorded day")
    func coverageSingular() {
        #expect(RecordedDaysSummary.coverageText(recorded: 1, total: 30) == "1 of 30 days has steps")
        #expect(RecordedDaysSummary.coverageText(recorded: 18, total: 30) == "18 of 30 days have steps")
    }

    // MARK: - Failed vs empty

    @Test("A failed query is unavailable, even when today has steps")
    func nilIsUnavailable() {
        let today = RecordedDaysSummary.make(days: [Day(steps: 4_000, goal: 8_000)])
        #expect(StepHistoryState.make(fetched: nil, summary: today) == .unavailable)
        #expect(StepHistoryState.make(fetched: nil, summary: RecordedDaysSummary.make(days: [])) == .unavailable)
    }

    @Test("A query that found nothing is empty, not unavailable")
    func emptyIsEmpty() {
        let none = RecordedDaysSummary.make(days: Array(repeating: Day(steps: 0, goal: 8_000), count: 30))
        #expect(StepHistoryState.make(fetched: [:], summary: none) == .empty)
    }

    @Test("A populated query shows its summary")
    func populatedIsRecorded() {
        let s = RecordedDaysSummary.make(days: Self.thirtyDays)
        #expect(StepHistoryState.make(fetched: [Date(timeIntervalSince1970: 0): 9_000], summary: s) == .recorded(s))
    }

    @Test("The empty and unavailable wording never claims access was denied")
    func neutralWording() {
        let all = [RecordedDaysSummary.noHealthData, RecordedDaysSummary.noHealthDataHint,
                   RecordedDaysSummary.noAppOnlyData, RecordedDaysSummary.unavailable,
                   RecordedDaysSummary.noHealthDataMonth, RecordedDaysSummary.noAppOnlyDataMonth]
        for text in all {
            #expect(!text.localizedCaseInsensitiveContains("denied"))
            #expect(!text.localizedCaseInsensitiveContains("permission"))
            #expect(!text.contains("0/0"))
        }
        #expect(Set(all).count == 6)
        // The hint names where the trend's "Check Health access" button goes.
        #expect(RecordedDaysSummary.noHealthDataHint.contains("Health app"))
        #expect(!RecordedDaysSummary.noHealthDataHint.contains("Settings"))
    }

    // MARK: - Month calendar's empty note

    @Test("The month's empty note waits for that month's Health answer")
    func monthEmptyNote() {
        let oct = Date(timeIntervalSince1970: 1_790_812_800)   // 2026-10-01 UTC
        let sep = Date(timeIntervalSince1970: 1_788_220_800)   // 2026-09-01 UTC
        func note(future: Bool = false, health: Bool = true, _ loaded: MonthEmptyNote.Loaded?) -> MonthEmptyNote {
            MonthEmptyNote.make(isFuture: future, healthKit: health, shown: oct, loaded: loaded)
        }
        #expect(note(nil) == .none, "no answer yet: say nothing")
        #expect(note(.init(month: sep, failed: false)) == .none, "the previous month's answer is still on screen")
        #expect(note(.init(month: oct, failed: true)) == .unavailable)
        #expect(note(.init(month: oct, failed: false)) == .empty)
        #expect(note(health: false, nil) == .empty, "App Only has no query to wait for")
        #expect(note(future: true, .init(month: oct, failed: false)) == .none)
    }

    // MARK: - Month and trend agree

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// Tuesday 2026-10-27 15:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_793_059_200 + 54_000)

    @Test("Days after today are in neither denominator")
    func futureDaysLeftOut() {
        let cal = Self.utc
        let today = cal.startOfDay(for: Self.now)
        let dates = (-3...3).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        let past = RecordedDaysSummary.pastDates(dates, today: Self.now, calendar: cal)
        #expect(past.count == 4)
        #expect(past.last == today)
    }

    @Test("Month and trend pick their days the same way: up to today, future values ignored")
    func monthTrendWindowing() {
        let cal = Self.utc
        let today = cal.startOfDay(for: Self.now)
        // October 2026 as the month grid has it (1st to 31st, future days
        // included), and the trend's last 30 days (Sep 28 to Oct 27).
        let october = (0..<31).compactMap {
            cal.date(byAdding: .day, value: $0, to: cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!)
        }
        let trend = (0..<30).compactMap { cal.date(byAdding: .day, value: $0 - 29, to: today) }
        // Steps on Oct 3, 10, 17, 24 and 27 (today); Sep 29 is outside October.
        let steps: [Date: Int] = [
            cal.date(from: DateComponents(year: 2026, month: 9, day: 29))!: 7_000,
            cal.date(from: DateComponents(year: 2026, month: 10, day: 3))!: 9_000,
            cal.date(from: DateComponents(year: 2026, month: 10, day: 10))!: 4_000,
            cal.date(from: DateComponents(year: 2026, month: 10, day: 17))!: 8_000,
            cal.date(from: DateComponents(year: 2026, month: 10, day: 24))!: 2_000,
            today: 5_000,
            // A future day with a value must not count on either screen.
            cal.date(from: DateComponents(year: 2026, month: 10, day: 30))!: 50_000
        ]
        func summary(_ dates: [Date]) -> RecordedDaysSummary {
            RecordedDaysSummary.make(days: RecordedDaysSummary.pastDates(dates, today: Self.now, calendar: cal)
                .map { RecordedDaysSummary.Day(steps: steps[$0], goal: 8_000) })
        }
        let month = summary(october)
        // The month's days that are also in the trend: Oct 1 to 27.
        let overlap = summary(october.filter { trend.contains($0) })
        #expect(month == overlap)
        #expect(month.recordedDays == 5)
        #expect(month.totalDays == 27)
        #expect(month.average == 5_600)       // 28,000 / 5
        #expect(month.goalsMet == 2)          // 9,000 and 8,000
        #expect(month.best == 9_000)
        #expect(month.coverageText == "5 of 27 days have steps")
        let thirty = summary(trend)
        #expect(thirty.recordedDays == 6)
        #expect(thirty.totalDays == 30)
        #expect(thirty.average == 5_833)      // 35,000 / 6
    }

    // MARK: - Each day's own goal

    private func goal(_ day: Int, stored: Int?, custom: Bool = false, weekdayGoals: [Int: Int] = [:]) -> Int {
        let cal = Self.utc
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: day))!
        return StepManager.goal(on: date, today: Self.now, calendar: cal, stored: stored,
                                useCustomSchedule: custom, weekdayGoals: weekdayGoals, dailyGoal: 10_000)
    }

    @Test("A past day keeps its stored goal; today and later use the schedule")
    func storedGoalForPastDaysOnly() {
        #expect(goal(20, stored: 6_000) == 6_000)          // Tue Oct 20, past
        #expect(goal(27, stored: 6_000) == 10_000)         // today
        #expect(goal(28, stored: 6_000) == 10_000)         // tomorrow
        #expect(goal(20, stored: nil) == 10_000)
    }

    @Test("Without a stored goal, a custom schedule gives the day's weekday goal")
    func customScheduleGoal() {
        // Sat Oct 24 is weekday 7; Mon Oct 26 is weekday 2 with no override.
        #expect(goal(24, stored: nil, custom: true, weekdayGoals: [7: 5_000]) == 5_000)
        #expect(goal(26, stored: nil, custom: true, weekdayGoals: [7: 5_000]) == 10_000)
        #expect(goal(24, stored: nil, custom: false, weekdayGoals: [7: 5_000]) == 10_000)
    }

    @Test("Goals met follows each day's stored goal, not today's")
    func goalsMetUsesStoredGoals() {
        // Today's goal is 10,000; Oct 20 and 21 were 6,000 days when walked.
        let days = [RecordedDaysSummary.Day(steps: 7_000, goal: goal(20, stored: 6_000)),
                    RecordedDaysSummary.Day(steps: 7_000, goal: goal(21, stored: 6_000)),
                    RecordedDaysSummary.Day(steps: 7_000, goal: goal(22, stored: nil))]
        #expect(RecordedDaysSummary.make(days: days).goalsMet == 2)
    }

    // MARK: - App Only steps by day

    @Test("Steps by day leaves rides out and adds a day's walks together")
    func humanStepsByDay() {
        let cal = Self.utc
        func session(_ activity: String, hoursAfterMidnight h: Double, steps: Int, meters: Double = 2_000) -> WalkSession {
            WalkSession(id: UUID(), routeName: "Test", date: Date(timeIntervalSince1970: 1_793_059_200 + h * 3_600),
                        elapsedTime: 1_800, totalDistance: meters, waypoints: [], lapCount: 1, isLoop: false,
                        activityType: activity, steps: steps)
        }
        let byDay = RecordedDaysSummary.humanStepsByDay([
            session("walking", hoursAfterMidnight: 8, steps: 3_000),
            session("running", hoursAfterMidnight: 18, steps: 4_000),
            session("cycling", hoursAfterMidnight: 12, steps: 0, meters: 20_000),
            session("walking", hoursAfterMidnight: -2, steps: 1_500)       // Mon Oct 26, 22:00
        ], calendar: cal)
        let tuesday = Date(timeIntervalSince1970: 1_793_059_200)
        #expect(byDay[tuesday] == 7_000)
        #expect(byDay[tuesday.addingTimeInterval(-86_400)] == 1_500)
        #expect(byDay.count == 2)
    }
}
