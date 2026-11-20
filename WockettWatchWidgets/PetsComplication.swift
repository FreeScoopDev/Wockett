import SwiftUI
import WidgetKit

/// The pets' steps today: the top pet in the small families, up to two in
/// the rectangle (`WatchGlanceDisplay.rectangularPetLimit`). With no pets it says how to add one, never an empty gauge.
/// Tapping it opens the Watch app.
struct PetsComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchWidgetKind.pets, provider: GlanceProvider()) { entry in
            PetsComplicationView(entry: entry)
                .containerBackground(for: .widget) { Color.earthBg }
        }
        .configurationDisplayName("Pets")
        .description("Your pets' steps today.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct PetsComplicationView: View {
    let entry: GlanceEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        switch entry.pets {
        case .placeholder: message(WatchGlanceDisplay.placeholderText)
        case .noPets: message(WatchGlanceDisplay.noPetsText)
        case .pets(let pets): content(pets)
        }
    }

    /// No numbers to show: the pets symbol and a line saying why.
    @ViewBuilder private func message(_ text: String) -> some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Pets", systemImage: WS.pets)
                    .font(.wktRowTitle)
                    .widgetAccentable()
                Text(text)
                    .font(.wktLabel)
                    .foregroundStyle(GlanceTint(mode: mode).secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Text(text)
        case .accessoryCorner:
            Image(systemName: WS.pets)
                .font(.wktRowTitle)
                .widgetAccentable()
                .widgetLabel(text)
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: WS.pets)
                    .font(.wktRowTitle)
                    .widgetAccentable()
            }
            .accessibilityLabel(text)
        }
    }

    @ViewBuilder private func content(_ pets: [WatchGlancePet]) -> some View {
        let tint = GlanceTint(mode: mode)
        if let top = pets.first {
            switch family {
            case .accessoryRectangular:
                let shown = WatchGlanceDisplay.rectangularPets(pets)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { pet in
                        HStack(spacing: 4) {
                            Text(pet.emoji)
                            Text(pet.name)
                                .font(.wktLabel)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(WatchGlanceDisplay.count(pet.steps))
                                .font(.wktLabel)
                                .foregroundStyle(tint.secondaryText)
                        }
                        Gauge(value: fraction(pet)) { EmptyView() }
                            .gaugeStyle(.accessoryLinearCapacity)
                            .tint(tint.pets)
                            .widgetAccentable()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(shown.map(spoken).joined(separator: ". "))
            case .accessoryInline:
                Text("\(top.emoji) \(top.name) \(WatchGlanceDisplay.count(top.steps)) steps")
            case .accessoryCorner:
                Text(top.emoji)
                    .font(.wktRowTitle)
                    .widgetLabel {
                        Gauge(value: fraction(top)) { EmptyView() }
                            .tint(tint.pets)
                    }
                    .accessibilityLabel(spoken(top))
            default:
                Gauge(value: fraction(top)) {
                    Text(top.emoji)
                } currentValueLabel: {
                    Text(WatchGlanceDisplay.compactCount(top.steps))
                }
                .gaugeStyle(.accessoryCircular)
                .tint(tint.pets)
                .widgetAccentable()
                .accessibilityLabel(spoken(top))
            }
        }
    }

    private func fraction(_ pet: WatchGlancePet) -> Double {
        WatchGlanceDisplay.Steps(steps: pet.steps, goal: pet.goal).fraction
    }

    private func spoken(_ pet: WatchGlancePet) -> String {
        "\(pet.name), \(WatchGlanceDisplay.count(pet.steps)) of \(WatchGlanceDisplay.count(pet.goal)) steps"
    }
}

#Preview("Pets, rectangular", as: .accessoryRectangular) {
    PetsComplication()
} timeline: {
    GlanceEntry(date: .now, snapshot: .sample(now: .now))
    GlanceEntry(date: .now, snapshot: .sample(now: .now, threePets: true))
    GlanceEntry(date: .now, snapshot: .sample(now: .now, pets: false))
}
