import Testing
import SwiftUI
import UIKit
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
            #expect(SessionPanelLayout.isLarge(size) == false, "\(size)")
            #expect(SessionPanelLayout.statColumns(size) == 3, "\(size)")
            #expect(SessionPanelLayout.stacksActions(size) == false, "\(size)")
            #expect(SessionPanelLayout.expandedMaxHeight(size) == 430, "\(size)")
        }
    }

    @Test func accessibilitySizesSwitch() {
        for size in Self.accessibility {
            #expect(SessionPanelLayout.isLarge(size), "\(size)")
            #expect(SessionPanelLayout.statColumns(size) == 2, "\(size)")
            #expect(SessionPanelLayout.stacksActions(size), "\(size)")
            #expect(SessionPanelLayout.expandedMaxHeight(size) == 220, "\(size)")
        }
    }

    /// Every size is in one list or the other, so a new case can't slip by.
    @Test func everySizeIsCovered() {
        #expect(Set(Self.normal + Self.accessibility) == Set(DynamicTypeSize.allCases))
    }

    /// The sizes behind the glance numbers' fonts: `wktMetric` (34 pt through
    /// `wktScaledSize`) at the normal sizes and `wktDense(34)` at the
    /// accessibility sizes never decrease as the text grows. This covers the
    /// DesignSystem sizing functions only, not which font `SessionStatTile`
    /// picks: putting another font in the view would not turn it red (critic,
    /// 2026-10-28). The first try used the card-title size there, which put
    /// AX1 below xxxLarge. Sizes in the order Settings offers them.
    @Test func glanceSizingFunctionsNeverShrinkAsTextGrows() {
        let categories: [(UIContentSizeCategory, Bool)] = [
            (.extraSmall, false), (.small, false), (.medium, false), (.large, false),
            (.extraLarge, false), (.extraExtraLarge, false), (.extraExtraExtraLarge, false),
            (.accessibilityMedium, true), (.accessibilityLarge, true), (.accessibilityExtraLarge, true),
            (.accessibilityExtraExtraLarge, true), (.accessibilityExtraExtraExtraLarge, true)
        ]
        var previous: CGFloat = 0
        for (category, large) in categories {
            let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(
                for: 34, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
            let size = large ? Font.wktDenseSize(34, scaled: scaled) : Font.wktScaledSize(34, scaled: scaled)
            #expect(size >= previous - 0.01, "\(category.rawValue): \(size) after \(previous)")
            previous = size
        }
        // xxxLarge, written out (TypeScaleCapTests): the accessibility sizes hold it.
        #expect(abs(previous - 44.667) < 0.01)
    }
}
