import Testing
import CoreGraphics
@testable import PoCSquat

/// The Routes results list gives the Start bar its height, down to a floor
/// (spec fix/route-start-visible, decision 6). Expected values are written
/// out for a round 900 pt container, not derived from the constants under
/// test. (On an iPhone 17e the Routes container is about 714 pt: 844 less the
/// status bar and the tab bar.)
struct ResultsPanelLayoutTests {
    @Test func noBarKeepsTheOldCap() {
        #expect(ResultsPanelLayout.scrollCap(container: 900, barHeight: 0) == 405)
    }

    @Test func theListGivesUpTheBarsHeight() {
        #expect(ResultsPanelLayout.scrollCap(container: 900, barHeight: 80) == 325)
        #expect(ResultsPanelLayout.scrollCap(container: 900, barHeight: 120) == 285)
    }

    @Test func neverBelowTheFloor() {
        // 405 - 135 = 270, exactly the floor.
        #expect(ResultsPanelLayout.scrollCap(container: 900, barHeight: 135) == 270)
        #expect(ResultsPanelLayout.scrollCap(container: 900, barHeight: 200) == 270)
    }

    @Test func aBarTallerThanTheRoomGivesTheFloor() {
        #expect(ResultsPanelLayout.scrollCap(container: 900, barHeight: 2_000) == 270)
    }

    @Test func neverAboveTheOldCap() {
        // A height measured as negative (never expected) must not grow the list.
        #expect(ResultsPanelLayout.scrollCap(container: 900, barHeight: -50) == 405)
    }
}
