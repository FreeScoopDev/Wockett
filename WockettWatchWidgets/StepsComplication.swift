import SwiftUI
import WidgetKit

/// Today's steps against the daily goal. Tapping it opens the Watch app.
struct StepsComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchWidgetKind.steps, provider: GlanceProvider()) { entry in
            StepsComplicationView(entry: entry)
                .containerBackground(for: .widget) { Color.earthBg }
        }
        .configurationDisplayName("Steps")
        .description("Today's steps against your daily goal.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct StepsComplicationView: View {
    let entry: GlanceEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        switch entry.steps {
        case .placeholder: placeholder
        case .steps(let steps): content(steps)
        }
    }

    @ViewBuilder private var placeholder: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Steps", systemImage: WS.steps)
                    .font(.wktRowTitle)
                    .widgetAccentable()
                Text(WatchGlanceDisplay.placeholderText)
                    .font(.wktLabel)
                    .foregroundStyle(GlanceTint(mode: mode).secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Text(WatchGlanceDisplay.placeholderText)
        case .accessoryCorner:
            Image(systemName: WS.steps)
                .font(.wktRowTitle)
                .widgetAccentable()
                .widgetLabel(WatchGlanceDisplay.placeholderText)
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: WS.steps)
                    .font(.wktRowTitle)
                    .widgetAccentable()
            }
            .accessibilityLabel(WatchGlanceDisplay.placeholderText)
        }
    }

    @ViewBuilder private func content(_ steps: WatchGlanceDisplay.Steps) -> some View {
        let tint = GlanceTint(mode: mode)
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Steps", systemImage: WS.steps)
                    .font(.wktLabel)
                    .foregroundStyle(tint.secondaryText)
                Text(WatchGlanceDisplay.count(steps.steps))
                    .font(.wktRowTitle)
                Gauge(value: steps.fraction) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(tint.steps)
                    .widgetAccentable()
                Text(WatchGlanceDisplay.progressLine(steps))
                    .font(.wktLabel)
                    .foregroundStyle(tint.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WatchGlanceDisplay.inline(steps))
        case .accessoryInline:
            Label(WatchGlanceDisplay.inline(steps), systemImage: WS.steps)
        case .accessoryCorner:
            Text(WatchGlanceDisplay.compactCount(steps.steps))
                .font(.wktRowTitle)
                .widgetCurvesContent()
                .widgetLabel {
                    Gauge(value: steps.fraction) { EmptyView() }
                        .tint(tint.steps)
                }
                .accessibilityLabel(WatchGlanceDisplay.inline(steps))
        default:
            Gauge(value: steps.fraction) {
                Image(systemName: WS.steps)
            } currentValueLabel: {
                Text(WatchGlanceDisplay.compactCount(steps.steps))
            }
            .gaugeStyle(.accessoryCircular)
            .tint(tint.steps)
            .widgetAccentable()
            .accessibilityLabel(WatchGlanceDisplay.inline(steps))
        }
    }
}

#Preview("Steps, rectangular", as: .accessoryRectangular) {
    StepsComplication()
} timeline: {
    GlanceEntry(date: .now, snapshot: .sample(now: .now))
    GlanceEntry(date: .now, snapshot: .sample(now: .now, steps: 10_400))
    GlanceEntry(date: .now, snapshot: nil)
}

#Preview("Steps, circular", as: .accessoryCircular) {
    StepsComplication()
} timeline: {
    GlanceEntry(date: .now, snapshot: .sample(now: .now))
}
