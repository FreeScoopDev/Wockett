import Testing
import SwiftUI
@testable import PoCSquat

/// The walk panel keeps its normal layout at every non-accessibility size
/// (three columns, Finish beside Pause, a 430 pt panel) and switches at every
/// accessibility size (spec fix/large-text-walk-screen). The expected values
/// are written out, not derived from `isAccessibilitySize`.
struct SessionPanelLayoutTests {
    private static let normal: [DynamicTypeSize] = [
        .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge
    ]
    private static let accessibility: [DynamicTypeSize] = [
        .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5
    ]

    @Test func normalSizesKeepTheLayout() {
        for size in Self.normal {
            #expect(SessionPanelLayout.statColumns(size) == 3, "\(size)")
            #expect(SessionPanelLayout.stacksActions(size) == false, "\(size)")
            #expect(SessionPanelLayout.expandedMaxHeight(size) == 430, "\(size)")
        }
    }

    @Test func accessibilitySizesSwitch() {
        for size in Self.accessibility {
            #expect(SessionPanelLayout.statColumns(size) == 2, "\(size)")
            #expect(SessionPanelLayout.stacksActions(size), "\(size)")
            #expect(SessionPanelLayout.expandedMaxHeight(size) == 220, "\(size)")
        }
    }

    /// Every size is in one list or the other, so a new case can't slip by.
    @Test func everySizeIsCovered() {
        #expect(Set(Self.normal + Self.accessibility) == Set(DynamicTypeSize.allCases))
    }
}
