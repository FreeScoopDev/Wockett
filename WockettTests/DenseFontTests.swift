import Testing
import SwiftUI
import UIKit
@testable import PoCSquat

/// `Font.wktDense` is what keeps the calendars, the Home ring and the Health
/// metric row from overflowing at the largest text sizes (2026-10-13).
struct DenseFontTests {
    private var capped: CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(
            for: 13, compatibleWith: UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge))
    }

    @Test func accessibilitySizesStopAtTheLargestOrdinarySize() {
        let huge = UIFontMetrics(forTextStyle: .body).scaledValue(
            for: 13, compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        #expect(huge > capped)
        #expect(Font.wktDenseSize(13, scaled: huge) == capped)
    }

    @Test func ordinarySizesAreUnchanged() {
        #expect(Font.wktDenseSize(13, scaled: 13) == 13)
        #expect(Font.wktDenseSize(13, scaled: 15) == 15)
    }
}
