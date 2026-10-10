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

/// The answer at the end of a sheet's task ("Thanks. We'll review it."): a
/// badge, a title, what happens next, and Done. One look in every sheet.
struct WktResultView: View {
    let symbol: WktSymbol
    let title: String
    let detail: String
    let onDone: () -> Void

    /// A warning reads as one in every sheet: orange, the rest green.
    private var tint: Color { symbol == .warning ? .earthOrange : .earthGreen }

    var body: some View {
        VStack(spacing: 16) {
            WktIconBadge(symbol: symbol, tint: tint, size: 64)
            Text(title)
                .font(.wktCardTitle).foregroundColor(.earthCream)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.wktBodyText).foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
            Spacer()
            WktPrimaryButton(title: "Done", action: onDone)
        }
        .padding(.horizontal, WktSpacing.screen)
        .padding(.vertical, 24)
    }
}

/// A small action inside a row ("Join", "Start"): a 30 pt `earthRaised`
/// capsule with green text. The tap target reaches 44 pt; the capsule does not.
struct WktPillButton: View {
    let title: String
    /// The text colour: green for the usual action, red to end something,
    /// `earthCream` for "Not now".
    var tint: Color = .earthGreen
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.wktLabel)
                .foregroundColor(tint)
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
/// `size` 48 is the large version heading a detail screen.
struct WktIconBadge: View {
    private let image: Image
    var tint: Color = .earthGreen
    var size: CGFloat = 36

    init(symbol: WktSymbol, tint: Color = .earthGreen, size: CGFloat = 36) {
        self.image = Image(wkt: symbol)
        self.tint = tint
        self.size = size
    }

    /// For a symbol a model supplies (a readiness level, a gait status), which
    /// CLAUDE.md allows to be variable-driven rather than a `WktSymbol` case.
    init(systemName: String, tint: Color = .earthGreen, size: CGFloat = 36) {
        self.image = Image(systemName: systemName)
        self.tint = tint
        self.size = size
    }

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        image
            // 20 pt (`WktIconSize.row`) in the standard badge; half the badge in a larger one.
            .font(.system(size: (size > 36 ? size * 0.5 : WktIconSize.row.points) * scale, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
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

/// The user's own progress toward a step goal: an orange ring on the track,
/// with whatever the screen puts in the middle. Orange is the user's goal
/// everywhere; green is the crew's and the action colour.
struct WktGoalRing<Center: View>: View {
    let progress: Double
    var lineWidth: CGFloat = 10
    /// Orange for the user. A pet's own screen passes the pet's colour, as
    /// the walk summary and the Community crew card show each pet.
    var tint: Color = .earthOrange
    @ViewBuilder let center: () -> Center

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.earthTrack, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: progress)
            center()
                .padding(lineWidth + 4)
        }
        // Inset by half the stroke so the ring never clips at its frame.
        .padding(lineWidth / 2)
    }
}

/// A 36 pt round icon button on `earthRaised` with a 44 pt tap target: the
/// previous / next / calendar controls beside a heading.
struct WktRoundIconButton: View {
    let symbol: WktSymbol
    let label: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(wkt: symbol)
                .wktIcon(.inline, tint: disabled ? .earthMuted.opacity(0.35) : .earthCream)
                .frame(width: 36, height: 36)
                .background(Color.earthRaised, in: Circle())
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(BounceButtonStyle(scale: 0.92))
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

/// A strip across the top of a panel saying something has happened mid-session
/// (paused, off the trail, too fast for a walk, hot out): a tinted band with an
/// icon, a title, a line of detail, and its actions on their own row so they
/// keep their size at large text sizes.
struct WktBanner<Leading: View, Actions: View>: View {
    let tint: Color
    let title: String
    var detail: String?
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                leading()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.wktRowTitle)
                        .foregroundColor(.earthCream)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.wktLabel)
                            .foregroundColor(.earthMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }
            if Actions.self != EmptyView.self {
                HStack(spacing: 8) { actions() }
                    .padding(.leading, 48)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.14))
    }
}

extension WktBanner where Leading == WktIconBadge {
    init(symbol: WktSymbol, tint: Color, title: String, detail: String? = nil,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.init(tint: tint, title: title, detail: detail,
                  leading: { WktIconBadge(symbol: symbol, tint: tint) }, actions: actions)
    }
}

/// Pick one of a few options laid side by side: Routes | Trails, Walk | Run |
/// Ride. The chosen one takes the action green, the rest are cards, as on
/// Home's activity picker. Each option is a button with its title as its
/// label, so UI tests and VoiceOver find it by name.
struct WktSegmentedPicker<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var symbol: WktSymbol?
    }

    @Binding var selection: Value
    let options: [Option]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let selected = selection == option.value
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { selection = option.value }
                } label: {
                    HStack(spacing: 6) {
                        if let symbol = option.symbol {
                            Image(wkt: symbol)
                                .wktIcon(.inline, tint: selected ? .white : .earthCream, onFill: selected)
                        }
                        Text(option.title)
                            .font(.wktLabel)
                            .foregroundColor(selected ? .white : .earthCream)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .wktChoiceBackground(selected: selected)
                }
                .buttonStyle(BounceButtonStyle(scale: 0.96))
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// One option in a scrolling row of choices ("Finish goal", "15 min"): a
/// capsule, action green when chosen, `earthRaised` when not.
struct WktChoiceChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.wktLabel)
                .foregroundColor(selected ? .white : .earthCream)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(selected ? Color.earthGreenFill : Color.earthRaised, in: Capsule())
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .padding(.vertical, -4)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.94))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Lays chips out left to right and wraps to a new line when a row is full,
/// so a card's tags never squeeze or run off its edge.
struct WktFlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
