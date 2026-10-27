import Testing
import Foundation
@testable import PoCSquat

struct StepManagerTests {

    // MARK: - Helpers

    private func day(
        steps: Int?,
        goal: Int,
        daysFromNow: Int = 0
    ) -> CalendarDay {
        let cal  = Calendar.current
        let base = cal.startOfDay(for: Date())
        let date = cal.date(byAdding: .day, value: daysFromNow, to: base) ?? base
        let wd   = cal.component(.weekday, from: date)
        return CalendarDay(id: date, date: date, weekday: wd, goal: goal,
                           steps: steps, tag: nil, tagEmoji: nil, tagColor: nil)
    }

    // MARK: - Progress

    @Test func progress_halfGoal() {
        #expect(day(steps: 5_000, goal: 10_000).progress == 0.5)
    }

    @Test func progress_clampedAtOne_whenStepsExceedGoal() {
        #expect(day(steps: 15_000, goal: 10_000).progress == 1.0)
    }

    @Test func progress_zeroWithNoSteps() {
        #expect(day(steps: nil, goal: 10_000).progress == 0.0)
    }

    @Test func progress_zeroWithZeroSteps() {
        #expect(day(steps: 0, goal: 10_000).progress == 0.0)
    }

    // MARK: - Goal met

    @Test func goalMet_trueWhenStepsEqualGoal() {
        #expect(day(steps: 10_000, goal: 10_000).goalMet == true)
    }

    @Test func goalMet_trueWhenStepsExceedGoal() {
        #expect(day(steps: 12_000, goal: 10_000).goalMet == true)
    }

    @Test func goalMet_falseWhenOneStepShort() {
        #expect(day(steps: 9_999, goal: 10_000).goalMet == false)
    }

    // MARK: - Edge: future day

    @Test func goalMet_nilForFutureDay() {
        // A future day never has a verdict, even when it carries a step count:
        // with `steps: nil` the nil-steps rule answers first and the future-day
        // rule is never reached (2026-09-28 audit). DayDetailSheet shows this.
        #expect(day(steps: 5_000, goal: 10_000, daysFromNow: 1).goalMet == nil)
        #expect(day(steps: 15_000, goal: 10_000, daysFromNow: 1).goalMet == nil)
    }

    // MARK: - ActivityTagConfig

    @Test func activityTagConfig_defaultCount() {
        #expect(ActivityTagConfig.defaults.count == 6)
    }

    @Test func activityTagConfig_colorIndex_wrapsAroundPalette() {
        let paletteSize = ActivityTagConfig.palette.count
        let config = ActivityTagConfig(id: "x", name: "X", emoji: "⭐", colorIndex: paletteSize * 3 + 1)
        // Compared with the palette itself: an expected value taken from the same
        // function passes for any constant (2026-09-28 audit).
        #expect(config.color == ActivityTagConfig.palette[1])
        #expect(config.color != ActivityTagConfig.palette[0])
    }

    // MARK: - Week strip, App Only mode

    /// The Home week strip in App Only mode totals recorded sessions per day.
    /// A ride's "steps" are only distance / 0.762 m, so a ride-only day is 0
    /// and a walk-plus-ride day is the walk's steps. Drives the real
    /// `refreshWeeklyCalendar`; it freezes past days' goals into
    /// UserDefaults, so the key is put back afterwards.
    @MainActor
    @Test("Week strip: a ride-only day shows 0 steps, a walk-plus-ride day the walk's")
    func weekStrip_appOnly_ridesAddNoSteps() async throws {
        let goalsKey = StepManager.UDKey.historicalDayGoals
        let savedGoals = UserDefaults.standard.object(forKey: goalsKey)
        defer {
            if let savedGoals { UserDefaults.standard.set(savedGoals, forKey: goalsKey) }
            else { UserDefaults.standard.removeObject(forKey: goalsKey) }
        }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func noon(daysAgo: Int) -> Date {
            cal.date(byAdding: .hour, value: 12, to: cal.date(byAdding: .day, value: -daysAgo, to: today)!)!
        }
        func session(_ activity: String, daysAgo: Int, meters: Double, steps: Int = 0) -> WalkSession {
            WalkSession(id: UUID(), routeName: "Test", date: noon(daysAgo: daysAgo), elapsedTime: 1_800,
                        totalDistance: meters, waypoints: [], lapCount: 1, isLoop: false,
                        activityType: activity, steps: steps)
        }
        let sessions = [
            session("cycling", daysAgo: 1, meters: 20_000),               // ride only
            session("walking", daysAgo: 2, meters: 3_000, steps: 5_000),  // walk + ride
            session("cycling", daysAgo: 2, meters: 20_000),
            session("running", daysAgo: 3, meters: 5_000, steps: 6_000),  // unchanged
        ]

        let manager = StepManager()
        manager.trackingMode = .appOnly
        await manager.refreshWeeklyCalendar(sessions: sessions)

        func steps(daysAgo: Int) -> Int? {
            let date = cal.date(byAdding: .day, value: -daysAgo, to: today)!
            return manager.weeklyCalendar.first { $0.date == date }?.steps
        }
        #expect(steps(daysAgo: 1) == 0)
        #expect(steps(daysAgo: 2) == 5_000)
        #expect(steps(daysAgo: 3) == 6_000)
    }
}
