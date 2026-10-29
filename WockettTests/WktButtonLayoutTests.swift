import Testing
import SwiftUI
@testable import PoCSquat

/// The shared buttons keep one line and their rows at every normal text size,
/// and wrap and stack at every accessibility size (spec fix/large-text-buttons).
/// The expected values are written out, not derived from `isAccessibilitySize`.
struct WktButtonLayoutTests {
    private static let normal: [DynamicTypeSize] = [
        .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge
    ]
    private static let accessibility: [DynamicTypeSize] = [
        .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5
    ]

    @Test func normalSizesKeepOneLineAndTheRow() {
        for size in Self.normal {
            #expect(WktButtonLayout.titleLineLimit(size) == 1, "\(size)")
            #expect(WktButtonLayout.stacksRow(size) == false, "\(size)")
        }
    }

    @Test func accessibilitySizesWrapAndStack() {
        for size in Self.accessibility {
            #expect(WktButtonLayout.titleLineLimit(size) == nil, "\(size)")
            #expect(WktButtonLayout.stacksRow(size), "\(size)")
        }
    }

    /// Every size is in one list or the other, so a new case can't slip by.
    @Test func everySizeIsCovered() {
        #expect(Set(Self.normal + Self.accessibility) == Set(DynamicTypeSize.allCases))
    }
}
