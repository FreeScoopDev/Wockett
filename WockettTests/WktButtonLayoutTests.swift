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
            #expect(WktButtonLayout.titleVerticalPadding(size) == 0, "\(size)")
        }
    }

    @Test func accessibilitySizesWrapAndStack() {
        for size in Self.accessibility {
            #expect(WktButtonLayout.titleLineLimit(size) == nil, "\(size)")
            #expect(WktButtonLayout.stacksRow(size), "\(size)")
            #expect(WktButtonLayout.titleVerticalPadding(size) == 8, "\(size)")
        }
    }

    /// Every size is in one list or the other, so a new case can't slip by.
    @Test func everySizeIsCovered() {
        #expect(Set(Self.normal + Self.accessibility) == Set(DynamicTypeSize.allCases))
    }
}

/// A busy button keeps its idle size (spec fix/large-text-leftovers item 2).
/// At Accessibility 2 the two-line Post buttons were 90 pt idle and 56 pt
/// while posting, and the text busy labels ("Finding routes…") had none of
/// the shared button's padding. Measured by laying the views out in a
/// hosting controller, at a phone's button width. The fonts here stay at the
/// test host's own text size (`wktHeading` scales through `UIFontMetrics`,
/// not the environment), so only the environment-driven rules change: the
/// line limit, the centring and the padding.
@MainActor
struct WktBusyLabelSizeTests {
    private static let width: CGFloat = 350
    private static let longTitle = "Post & Save to My Routes"

    private func size(_ view: some View, _ typeSize: DynamicTypeSize) -> CGSize {
        let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, typeSize))
        return host.sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude))
    }

    @Test(arguments: [DynamicTypeSize.large, .accessibility2])
    func busyPrimaryLabelKeepsTheIdleSize(_ typeSize: DynamicTypeSize) {
        let idle = size(WktPrimaryLabel(title: Self.longTitle, symbol: .share), typeSize)
        let busy = size(WktPrimaryLabel(title: Self.longTitle, symbol: .share, busy: true), typeSize)
        #expect(busy == idle)
    }

    /// Guards the test above: at Accessibility 2 the idle label is taller than
    /// the 56 pt minimum, so "same size" is not two minimums agreeing.
    @Test func idleLabelOutgrowsTheMinimumAtAccessibility2() {
        let normal = size(WktPrimaryLabel(title: Self.longTitle, symbol: .share), .large)
        let large = size(WktPrimaryLabel(title: Self.longTitle, symbol: .share), .accessibility2)
        #expect(normal.height == 56)
        #expect(large.height > 56)
    }

    /// A hand-drawn busy title gets the shared button's padding: 8 pt above
    /// and below at the accessibility sizes, none at the normal sizes.
    @Test func busyTitleLayoutPadsAtAccessibilitySizes() {
        let title = Text("Finding routes…").font(.wktHeading(17)).wktButtonTitleLayout()
        let bare = size(Text("Finding routes…").font(.wktHeading(17)), .large)
        #expect(size(title, .large).height == bare.height)
        #expect(size(title, .accessibility2).height == bare.height + 16)
    }
}
