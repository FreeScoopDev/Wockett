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
/// while posting, and "Syncing…" was 56 pt under a two-line "Join & Sync
/// Distance". Measured by laying the views out in a hosting controller. The
/// fonts here stay at the test host's own text size (`wktHeading` scales
/// through `UIFontMetrics`, not the environment), so only the
/// environment-driven rules change: the line limit, the padding and the
/// icon's scaled size. A narrow width stands in for a large font.
@MainActor
struct WktBusyLabelSizeTests {
    private func size(_ view: some View, _ typeSize: DynamicTypeSize, width: CGFloat) -> CGSize {
        let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, typeSize))
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private func syncLabel(busy: Bool) -> some View {
        WktBusyLabel(isBusy: busy) {
            WktPrimaryLabel(title: "Join & Sync Distance for the whole of this challenge")
        } busy: {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.85)
                Text("Syncing…").font(.wktHeading(17))
            }
        }
    }

    private func postLabel(busy: Bool) -> some View {
        WktBusyLabel(isBusy: busy) {
            WktPrimaryLabel(title: "Post & Save to My Routes", symbol: .share)
        } busy: {
            ProgressView()
        }
    }

    /// A title that wraps to more lines than its busy title does.
    @Test(arguments: [DynamicTypeSize.large, .accessibility2])
    func busyTextKeepsTheIdleSize(_ typeSize: DynamicTypeSize) {
        #expect(size(syncLabel(busy: true), typeSize, width: 150)
                == size(syncLabel(busy: false), typeSize, width: 150))
    }

    /// A spinner on its own under a label whose icon grows at Accessibility 2.
    @Test(arguments: [DynamicTypeSize.large, .accessibility2])
    func busySpinnerKeepsTheIdleSize(_ typeSize: DynamicTypeSize) {
        #expect(size(postLabel(busy: true), typeSize, width: 350)
                == size(postLabel(busy: false), typeSize, width: 350))
    }

    /// Guards the two tests above: at Accessibility 2 both idle labels are
    /// taller than the 56 pt minimum (the sync title wraps to three lines or more,
    /// "Syncing…" to two at most), so
    /// "same size" is not two minimums agreeing.
    @Test func idleLabelsOutgrowTheMinimumAtAccessibility2() {
        let oneLine = size(Text("Syncing…").font(.wktHeading(17)), .large, width: 150).height
        #expect(size(syncLabel(busy: false), .accessibility2, width: 150).height >= 3 * oneLine + 16)
        #expect(size(postLabel(busy: false), .accessibility2, width: 350).height > 56)
        #expect(size(postLabel(busy: false), .large, width: 350).height == 56)
    }

    /// A busy title gets the shared button's padding: 8 pt above and below at
    /// the accessibility sizes, none at the normal sizes.
    @Test func busyTitleLayoutPadsAtAccessibilitySizes() {
        let title = Text("Finding routes…").font(.wktHeading(17)).wktButtonTitleLayout()
        let bare = size(Text("Finding routes…").font(.wktHeading(17)), .large, width: 350)
        #expect(size(title, .large, width: 350).height == bare.height)
        #expect(size(title, .accessibility2, width: 350).height == bare.height + 16)
    }
}
