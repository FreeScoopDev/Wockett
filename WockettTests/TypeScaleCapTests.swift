import Testing
import SwiftUI
import UIKit
@testable import PoCSquat

/// `Font.wktScaledSize` holds `wktHeading`, `wktBody` and `wktLabel` (and the
/// roles built on them) at their Accessibility 2 size, which is what
/// `.dynamicTypeSize(...DynamicTypeSize.accessibility2)` in `SquatCounterApp`
/// promised but could not do for these fonts (F5 audit, 2026-10-28).
///
/// The expected sizes are written out by hand, so the test does not compute
/// its answer with the code it checks. Up to AX2 they are what
/// `UIFontMetrics(forTextStyle: .body)` gives on iOS 26.5 (read 2026-10-28;
/// it is not a straight multiple of the body size: 13 pt is 17 at xxxLarge,
/// not 13 × 23/17). At AX3 and AX5 they repeat the AX2 size, which is the
/// point: unclamped, 13 pt would be 28.3 and 36.7 there.
struct TypeScaleCapTests {
    private static func scaled(_ size: CGFloat, at category: UIContentSizeCategory) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(
            for: size, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    }

    /// size → expected point size at large, xxxLarge, AX1, AX2, AX3, AX5.
    private static let expected: [(size: CGFloat, sizes: [CGFloat])] = [
        (13, [13, 17, 20, 23.667, 23.667, 23.667]),
        (15, [15, 19.667, 23.333, 27.333, 27.333, 27.333]),
        (16, [16, 21, 24.667, 29, 29, 29]),
        (19, [19, 25, 29.333, 34.667, 34.667, 34.667]),
        (22, [22, 29, 34, 40, 40, 40]),
        (34, [34, 44.667, 52.667, 61.667, 61.667, 61.667])
    ]
    private static let categories: [UIContentSizeCategory] = [
        .large, .extraExtraExtraLarge, .accessibilityMedium,
        .accessibilityLarge, .accessibilityExtraLarge, .accessibilityExtraExtraExtraLarge
    ]

    @Test func eachRoleSizeAtEachTextSize() {
        for row in Self.expected {
            for (category, want) in zip(Self.categories, row.sizes) {
                let got = Font.wktScaledSize(row.size, scaled: Self.scaled(row.size, at: category))
                #expect(abs(got - want) < 0.01, "\(row.size) pt at \(category.rawValue): \(got), want \(want)")
            }
        }
    }

    /// The clamp only matters if the unclamped size is larger: guards the test
    /// above against a platform where AX3 and AX5 stop growing by themselves.
    @Test func accessibility3And5WouldOtherwiseBeLarger() {
        for row in Self.expected {
            let ax2 = row.sizes[3]
            #expect(Self.scaled(row.size, at: .accessibilityExtraLarge) > ax2 + 1)
            #expect(Self.scaled(row.size, at: .accessibilityExtraExtraExtraLarge) > ax2 + 1)
        }
    }

    /// The cap is the same text size the app's `.dynamicTypeSize` limit names.
    @Test func capIsSwiftUIsAccessibility2() {
        #expect(DynamicTypeSize(Font.wktTextSizeCap) == .accessibility2)
    }

    /// `wktDense` keeps its own, lower cap (xxxLarge), below the type scale's.
    @Test func denseStaysAtItsLowerCap() {
        let ax5 = Self.scaled(13, at: .accessibilityExtraExtraExtraLarge)
        #expect(abs(Font.wktDenseSize(13, scaled: ax5) - 17) < 0.01)
        #expect(Font.wktDenseSize(13, scaled: ax5) < Font.wktScaledSize(13, scaled: ax5))
    }
}
