import Testing
@testable import PoCSquat

/// Goal and badge percentages round down everywhere (2026-10-07): a pet read
/// 47% on Home and 46% in its detail, and an unearned badge read "100%".
@Suite struct WktPercentTests {
    @Test func roundsDownSoAlmostDoneIsNeverHundred() {
        #expect(WktPercent.text(0.995) == "99%")
        #expect(WktPercent.text(0.9999) == "99%")
        #expect(WktPercent.text(1.0) == "100%")
    }

    @Test func homeAndPetDetailAgree() {
        // 0.466 rounded to 47 on Home and truncated to 46 in the pet detail.
        #expect(WktPercent.text(0.466) == "46%")
        #expect(WktPercent.text(0.476) == "47%")
    }

    @Test func binaryFractionsDoNotLoseAPoint() {
        // 0.29 * 100 is 28.999… in Double; plain truncation showed 28%.
        #expect(WktPercent.text(0.29) == "29%")
        #expect(WktPercent.text(0.57) == "57%")
    }

    @Test func overGoalAndOddInputs() {
        #expect(WktPercent.text(1.234) == "123%")
        #expect(WktPercent.text(0) == "0%")
        #expect(WktPercent.text(-0.2) == "0%")
        #expect(WktPercent.text(.nan) == "0%")
        #expect(WktPercent.text(.infinity) == "0%")
    }
}
