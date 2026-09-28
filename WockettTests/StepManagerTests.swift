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
}
