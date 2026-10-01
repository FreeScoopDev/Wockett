import SwiftUI

// MARK: - Shared controls (2026-09-30 Home redesign)
//
// The small pieces every screen builds from, beside `wktCard`,
// `WktSectionHeader` and `WktProgressBar` in WktCard.swift. Status is always a
// `WktStatusChip`, never a card; a screen has at most one `WktPrimaryButton`.

/// A 30 pt capsule for a status: GPS, weather. Pass `action` to make it a button.
struct WktStatusChip<Leading: View>: View {
    let text: String
    var textColor: Color = .earthCream
    var action: (() -> Void)?
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        if let action {
            Button(action: action) { chip }
                .buttonStyle(BounceButtonStyle(scale: 0.95))
        } else {
            chip
        }
    }

    private var chip: some View {
        HStack(spacing: 6) {
            leading()
            Text(text)
                .font(.wktLabel)
                .foregroundColor(textColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 30)
        .background(Color.earthRaised, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

extension WktStatusChip where Leading == WktStatusDot {
    /// A chip led by a coloured dot: "● GPS".
    init(text: String, dot: Color, textColor: Color = .earthCream, action: (() -> Void)? = nil) {
        self.init(text: text, textColor: textColor, action: action) { WktStatusDot(color: dot) }
    }
}

/// The 7 pt dot in a status chip.
struct WktStatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

/// The screen's one main action: 56 pt, radius 18, `earthGreenFill`, white heavy text.
struct WktPrimaryButton: View {
    let title: String
    var symbol: WktSymbol?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(wkt: symbol)
                        .wktIcon(.row, tint: .white, onFill: true)
                }
                Text(title)
                    .font(.wktHeading(17))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .background(Color.earthGreenFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(BounceButtonStyle(scale: 0.98))
    }
}

/// A 36 pt rounded square with a tinted fill and the glyph in the tint.
struct WktIconBadge: View {
    let symbol: WktSymbol
    var tint: Color = .earthGreen

    var body: some View {
        Image(wkt: symbol)
            .wktIcon(.row, tint: tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .accessibilityHidden(true)
    }
}
