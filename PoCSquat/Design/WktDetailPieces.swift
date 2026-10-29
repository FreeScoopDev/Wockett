import SwiftUI

// MARK: - Metric detail pieces
//
// The parts of a "one health metric" screen: Sleep, Readiness and Active
// Calories (RecoveryViews) and the four gait metrics (GaitHealthView). The two
// drew their own copies of each until the 2026-09-30 Health conversion.

/// The top of a metric screen: a large icon badge, the value, a row of
/// status chips, and a line saying what the value is.
struct WktMetricHero<Chips: View>: View {
    let badge: WktIconBadge
    let value: String
    var valueColor: Color = .earthCream
    let subtitle: String
    @ViewBuilder let chips: () -> Chips

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            badge
            VStack(alignment: .leading, spacing: 6) {
                Text(value)
                    .font(.wktMetric.monospacedDigit())
                    .foregroundColor(valueColor)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                HStack(spacing: 6) { chips() }
                Text(subtitle)
                    .font(.wktBodyText)
                    .foregroundColor(.earthMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

extension WktMetricHero where Chips == EmptyView {
    init(badge: WktIconBadge, value: String, valueColor: Color = .earthCream, subtitle: String) {
        self.init(badge: badge, value: value, valueColor: valueColor, subtitle: subtitle) { EmptyView() }
    }
}

/// Two columns of small stat cards: a label, the value, and a note on what
/// period it covers.
struct WktStatGrid: View {
    struct Item {
        let label: String
        let value: String
        let note: String
    }
    let items: [Item]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: WktSpacing.betweenCards), count: 2),
                  spacing: WktSpacing.betweenCards) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.label)
                        .font(.wktLabel)
                        .foregroundColor(.earthMuted)
                    Text(item.value)
                        .font(.wktCardTitle.monospacedDigit())
                        .foregroundColor(.earthCream)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    // Wraps rather than truncating at large text sizes:
                    // a note like "of 18 recorded days" is the denominator.
                    Text(item.note)
                        .font(.wktLabel)
                        .foregroundColor(.earthMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .wktCard()
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// How a row of three or four stats lays out. Side by side at the normal
/// text sizes; in rows of two at the accessibility sizes, where a third or a
/// quarter of the width cut the labels to "Distanc / e", "This w…",
/// "Day str…", "Goal str…" and the values to "About 29…" (F5 audit H3-H5,
/// N2, N3, 2026-10-29). Pet detail already used rows of two and read in
/// full. Pure, so a test can pin both.
enum WktStatColumns {
    /// `nil` at the normal sizes: one row, as many stats as it has. Two
    /// columns at the accessibility sizes.
    static func columns(_ size: DynamicTypeSize) -> Int? {
        size.isAccessibilitySize ? 2 : nil
    }

    /// A stat's label: one line at the normal sizes; at the accessibility
    /// sizes as many as it needs, broken between words. Values stay on one.
    static func labelLineLimit(_ size: DynamicTypeSize) -> Int? {
        size.isAccessibilitySize ? nil : 1
    }

    /// A wrapped label's lines, centred under a centred value. The normal
    /// sizes keep SwiftUI's default, `.leading`: a one-line label that
    /// shrinks to fit is drawn differently once centred (measured: History's
    /// and the You card's labels moved at the default size).
    static func labelAlignment(_ size: DynamicTypeSize) -> TextAlignment {
        size.isAccessibilitySize ? .center : .leading
    }
}

/// A row of stats that follows `WktStatColumns`: an `HStack` at the normal
/// sizes (exactly the row each screen had), rows of two at the
/// accessibility sizes. Only the arrangement: each screen keeps its own tile.
struct WktStatRow<Content: View>: View {
    var spacing: CGFloat = WktSpacing.betweenCards
    /// Between the rows of two; `spacing` when nil.
    var rowSpacing: CGFloat?
    @ViewBuilder let content: () -> Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if let columns = WktStatColumns.columns(typeSize) {
            WktStatColumnsLayout(columns: columns, spacing: spacing, rowSpacing: rowSpacing ?? spacing) {
                content()
            }
        } else {
            HStack(spacing: spacing) { content() }
        }
    }
}

/// Equal-width columns, filled row by row. A row is as tall as its tallest
/// stat, offered to each so a tile that fills its height stays even with its
/// neighbour; a last stat on its own keeps one column's width. A row with
/// fewer stats than columns (a ride's trail detail has only Length) uses
/// just as many columns, so one stat keeps the full width.
struct WktStatColumnsLayout: Layout {
    let columns: Int
    let spacing: CGFloat
    let rowSpacing: CGFloat

    /// Where each stat goes in a row `width` wide, given how tall each is at
    /// one column's width. Pure, so the arithmetic is tested without a view.
    static func frames(columns: Int, spacing: CGFloat, rowSpacing: CGFloat, width: CGFloat,
                       heightAt: (_ index: Int, _ columnWidth: CGFloat) -> CGFloat, count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = max(1, min(columns, count))
        let cellWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var frames: [CGRect] = []
        var y: CGFloat = 0
        for start in stride(from: 0, to: count, by: columns) {
            let row = start..<min(start + columns, count)
            let height = row.map { heightAt($0, cellWidth) }.max() ?? 0
            for index in row {
                let x = CGFloat(index - start) * (cellWidth + spacing)
                frames.append(CGRect(x: x, y: y, width: cellWidth, height: height))
            }
            y += height + rowSpacing
        }
        return frames
    }

    private func frames(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        Self.frames(columns: columns, spacing: spacing, rowSpacing: rowSpacing, width: width,
                    heightAt: { subviews[$0].sizeThatFits(ProposedViewSize(width: $1, height: nil)).height },
                    count: subviews.count)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = proposed
        } else {
            let used = CGFloat(max(1, min(columns, subviews.count)))
            let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            width = widest * used + spacing * (used - 1)
        }
        return CGSize(width: width, height: frames(subviews, width: width).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, frame) in frames(subviews, width: bounds.width).enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading,
                                  proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

/// Orange-dotted lines of text: what affects a metric.
struct WktBulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color.earthOrange)
                        .frame(width: 6, height: 6)
                        .padding(.top, 7)
                        .accessibilityHidden(true)
                    Text(item)
                        .font(.wktBodyText)
                        .foregroundColor(.earthMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Numbered steps in green circles: how to improve a metric.
struct WktNumberedList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(items.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(i + 1)")
                        .font(.wktLabel)
                        .foregroundColor(.earthGreen)
                        .frame(width: 26, height: 26)
                        .background(Color.earthGreen.opacity(0.16), in: Circle())
                        .accessibilityHidden(true)
                    Text(items[i])
                        .font(.wktBodyText)
                        .foregroundColor(.earthMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A titled block of explanation: a `WktSection` with one card.
struct WktInfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        WktSection(title: title) {
            content().wktCard()
        }
    }
}

/// A third-width stat card with its icon on top: distance, time, steps on a
/// summary. Three sit side by side, two at the accessibility sizes
/// (`WktStatRow`). An optional `detail` line goes under the
/// label (a climb's descent). `fillsHeight` lets a tile stretch to its row's
/// height, for a row sized to its tallest tile (`fixedSize` vertically), so a
/// row with one detail line stays even; off, a tile is its natural height.
struct WktIconStatTile: View {
    let value: String
    let label: String
    let symbol: WktSymbol
    var tint: Color = .earthGreen
    var detail: String?
    var accessibilityDetail: String?
    var fillsHeight = false

    var body: some View {
        VStack(spacing: 8) {
            WktIconBadge(symbol: symbol, tint: tint)
            Text(value)
                .font(.wktRowTitle)
                .foregroundColor(.earthCream)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.wktLabel).foregroundColor(.earthMuted)
            if let detail {
                Text(detail)
                    .font(.wktLabel)
                    .foregroundColor(.earthMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
        .padding(.vertical, 16)
        .padding(.horizontal, 6)
        .wktCardBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([ "\(value) \(label)", accessibilityDetail ?? detail ]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: - Badge ring

/// A badge's emoji inside its progress ring: green once earned, the notice
/// colour while in progress, the emoji greyed out until it is earned. Drawn
/// the same in the Badges grid and on Home, where pinned badges sit in the
/// streak row.
struct WktBadgeRing: View {
    let emoji: String
    let progress: Double
    let earned: Bool
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.earthTrack, lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(earned ? Color.earthGreen : Color.accentNotice,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(emoji) // the badge's own emoji (data)
                .font(.system(size: size * 0.59))
                .opacity(earned ? 1.0 : 0.25)
                .grayscale(earned ? 0 : 1)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
