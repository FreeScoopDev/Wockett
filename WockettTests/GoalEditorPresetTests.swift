import Testing
@testable import PoCSquat

/// The labels on the goal editor's preset chips. Until 2026-10-01, 5,000 read
/// "5.5K" and 12,500 read "12K": the old formula assumed every preset under
/// 10,000 was a half-thousand and every one above it a whole thousand.
struct GoalEditorPresetTests {

    @Test func wholeThousands_haveNoDecimal() {
        #expect(GoalEditorSheet.presetLabel(5_000) == "5K")
        #expect(GoalEditorSheet.presetLabel(10_000) == "10K")
        #expect(GoalEditorSheet.presetLabel(20_000) == "20K")
    }

    @Test func halfThousands_keepTheirHalf() {
        #expect(GoalEditorSheet.presetLabel(7_500) == "7.5K")
        #expect(GoalEditorSheet.presetLabel(12_500) == "12.5K")
    }
}
