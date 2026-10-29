import Testing
import SwiftUI
@testable import PoCSquat

/// Stat rows keep one row and one-line labels at every normal text size, and
/// go to two columns with wrapping labels at every accessibility size (spec
/// fix/large-text-stat-rows). The expected values are written out, not
/// derived from `isAccessibilitySize`.
struct WktStatColumnsTests {
    private static let normal: [DynamicTypeSize] = [
        .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge
    ]
    private static let accessibility: [DynamicTypeSize] = [
        .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5
    ]

    @Test func normalSizesKeepOneRowAndOneLine() {
        for size in Self.normal {
            #expect(WktStatColumns.columns(size) == nil, "\(size)")
            #expect(WktStatColumns.labelLineLimit(size) == 1, "\(size)")
            #expect(WktStatColumns.labelAlignment(size) == .leading, "\(size)")
        }
    }

    @Test func accessibilitySizesUseTwoColumnsAndWrap() {
        for size in Self.accessibility {
            #expect(WktStatColumns.columns(size) == 2, "\(size)")
            #expect(WktStatColumns.labelLineLimit(size) == nil, "\(size)")
            #expect(WktStatColumns.labelAlignment(size) == .center, "\(size)")
        }
    }

    /// Every size is in one list or the other, so a new case can't slip by.
    @Test func everySizeIsCovered() {
        #expect(Set(Self.normal + Self.accessibility) == Set(DynamicTypeSize.allCases))
    }
}
