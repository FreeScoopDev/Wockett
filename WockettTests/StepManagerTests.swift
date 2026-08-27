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
        // Future days have no step data yet — goalMet must be nil
        #expect(day(steps: nil, goal: 10_000, daysFromNow: 1).goalMet == nil)
    }

    @Test func progress_zeroForFutureDay() {
        #expect(day(steps: nil, goal: 10_000, daysFromNow: 1).progress == 0.0)
    }

    // MARK: - ActivityTagConfig

    @Test func activityTagConfig_defaultCount() {
        #expect(ActivityTagConfig.defaults.count == 6)
    }

    @Test func activityTagConfig_colorIndex_wrapsAroundPalette() {
        let paletteSize = ActivityTagConfig.palette.count
        let config = ActivityTagConfig(id: "x", name: "X", emoji: "⭐", colorIndex: paletteSize * 3 + 1)
        // Should not crash; index must wrap.
        let color = config.color
        let expected = ActivityTagConfig(id: "x", name: "X", emoji: "⭐", colorIndex: 1).color
        #expect(color == expected)
    }
}
