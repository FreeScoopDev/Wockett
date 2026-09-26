import SwiftUI

// MARK: - Cards and section labels
//
// The card Home's sections sit on (stat card, THE CREW) and the small
// all-caps label with a green link that heads them, as shared pieces so the
// Community hub and later screens look the same as Home rather than
// approximating it (Joe's standard, 2026-09-04: shared components look the
// same everywhere they appear). Before this, every screen drew its own card
// with radii of 12, 14, 16 or 18 and three different header styles.

extension View {
    /// Content on the app's card: `earthCard`, radius 18, as Home's cards.
    func wktCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.earthCard)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// "THE CREW ········ Manage ›": a card's eyebrow label and optional link.
struct WktSectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .wktTechnical(10)
                .foregroundColor(.earthMuted)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    Text("\(actionTitle) ›")
                        .font(.wktBody(12))
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
        .frame(minHeight: 20)
    }
}

/// A thin rounded progress bar in one tint, as on the badge and crew cards.
struct WktProgressBar: View {
    let value: Double
    var tint: Color = .earthOrange
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // earthLine disappears on dark cards; a muted tint shows in both.
                Capsule().fill(Color.earthMuted.opacity(0.22))
                Capsule().fill(tint)
                    .frame(width: max(height, geo.size.width * min(1, max(0, value))))
                    .opacity(value > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
