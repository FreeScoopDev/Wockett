import SwiftUI

// MARK: - Cards and section labels
//
// The card every screen's content sits on and the heading above a section,
// as shared pieces so every screen looks the same as Home rather than
// approximating it (Joe's standard, 2026-09-04: shared components look the
// same everywhere they appear). Before this, every screen drew its own card
// with radii of 12, 14, 16 or 18 and three different header styles.
//
// 2026-09-30 Home redesign: radius 22 with a hairline stroke, and the header
// is a sentence-case rounded heading instead of an all-caps mono eyebrow.
// Changed here rather than beside a new variant, so every screen moved too.

extension View {
    /// Content on the app's card: `earthCard`, radius 22, 1 pt `earthStroke`.
    func wktCard(padding: CGFloat = WktSpacing.cardPadding) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .wktCardBackground()
    }

    /// The card's fill, shape and stroke without its padding or width, for
    /// content that lays itself out (a button label, a fixed-height tile).
    func wktCardBackground(fill: Color = .earthCard) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return self
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(Color.earthStroke, lineWidth: 1))
            .contentShape(shape)
    }

    /// One option in a set the user picks from (an activity, a goal, a
    /// duration): the action green when chosen, a card when not. The caller
    /// sets its own text colour, white when `selected`.
    func wktChoiceBackground(selected: Bool) -> some View {
        wktCardBackground(fill: selected ? .earthGreenFill : .earthCard)
    }
}

/// "Routes ········ See all": a section's heading and optional link.
struct WktSectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.wktSection)
                .foregroundColor(.earthCream)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.wktBodyText)
                        .foregroundColor(.earthGreen)
                        // A 44 pt target without a 44 pt row: the tap area
                        // reaches past the label, the layout does not.
                        .padding(.vertical, 12)
                        .padding(.leading, 12)
                        .contentShape(Rectangle())
                        .padding(.vertical, -12)
                        .padding(.leading, -12)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 24)
    }
}

/// The 1 pt rule between rows inside a card.
struct WktDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.earthTrack)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A section: its `WktSectionHeader` above, its card or cards below, 12 pt
/// apart. Headings sit above cards, not inside them, on every screen.
struct WktSection<Content: View>: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: WktSpacing.betweenCards) {
            WktSectionHeader(title: title, actionTitle: actionTitle, action: action)
            content()
        }
    }
}

/// A rounded progress bar in one tint: orange for the user's own goal,
/// green for a crew member's.
struct WktProgressBar: View {
    let value: Double
    var tint: Color = .earthOrange
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.earthTrack)
                Capsule().fill(tint)
                    .frame(width: max(height, geo.size.width * min(1, max(0, value))))
                    .opacity(value > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
