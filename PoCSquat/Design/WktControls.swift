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
        Button(action: action) { WktPrimaryLabel(title: title, symbol: symbol) }
            .buttonStyle(BounceButtonStyle(scale: 0.98))
    }
}

/// The quieter partner to `WktPrimaryButton` when two actions sit together:
/// same size and shape, `earthRaised` fill, `earthCream` text.
struct WktSecondaryButton: View {
    let title: String
    var symbol: WktSymbol?
    let action: () -> Void

    var body: some View {
        Button(action: action) { WktSecondaryLabel(title: title, symbol: symbol) }
            .buttonStyle(BounceButtonStyle(scale: 0.98))
    }
}

/// `WktPrimaryButton`'s look, for a control that is not a plain `Button`
/// (a `ShareLink`, a `NavigationLink`).
struct WktPrimaryLabel: View {
    let title: String
    var symbol: WktSymbol?

    var body: some View {
        WktButtonLabel(title: title, symbol: symbol, fill: .earthGreenFill, text: .white, onFill: true)
    }
}

/// `WktSecondaryButton`'s look, for a control that is not a plain `Button`.
struct WktSecondaryLabel: View {
    let title: String
    var symbol: WktSymbol?

    var body: some View {
        WktButtonLabel(title: title, symbol: symbol, fill: .earthRaised, text: .earthCream, onFill: false)
    }
}

private struct WktButtonLabel: View {
    let title: String
    let symbol: WktSymbol?
    let fill: Color
    let text: Color
    let onFill: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        HStack(spacing: 8) {
            if let symbol {
                Image(wkt: symbol)
                    .wktIcon(.row, tint: text, onFill: onFill)
            }
            Text(title)
                .font(.wktHeading(17))
                .foregroundColor(text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 56)
        .background(fill, in: shape)
        .contentShape(shape)
    }
}

/// A small action inside a row ("Join", "Start"): a 30 pt `earthRaised`
/// capsule with green text. The tap target reaches 44 pt; the capsule does not.
struct WktPillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.wktLabel)
                .foregroundColor(.earthGreen)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 30)
                .background(Color.earthRaised, in: Capsule())
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .padding(.vertical, -7)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.95))
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

/// A screen with nothing to show yet, or a load that failed: the 44 pt hero
/// glyph, an optional title, the message, and an optional action under it.
struct WktEmptyState: View {
    let symbol: WktSymbol
    var tint: Color = .earthMuted
    var title: String?
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(wkt: symbol).wktIcon(.hero, tint: tint)
                .accessibilityHidden(true)
            if let title {
                Text(title)
                    .font(.wktRowTitle)
                    .foregroundColor(.earthCream)
                    .multilineTextAlignment(.center)
            }
            Text(message)
                .font(.wktBodyText)
                .foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                WktPillButton(title: actionTitle, action: action)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
    }
}
