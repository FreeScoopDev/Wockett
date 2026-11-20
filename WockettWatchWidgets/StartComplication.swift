import SwiftUI
import WidgetKit

/// The Start launcher: opens the Watch app on its idle picker (or the live
/// screen while a session runs). The tap itself starts nothing; the person
/// picks an activity and presses Start in the app, as before.
struct StartComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchWidgetKind.start, provider: StartProvider()) { _ in
            StartComplicationView()
                .widgetURL(WatchWidgetLink.start)
                .containerBackground(for: .widget) { Color.earthBg }
        }
        .configurationDisplayName("Start")
        .description("Opens Wockett to choose and start an activity.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner])
    }
}

/// Nothing changes on the launcher, so one entry, never reloaded.
struct StartProvider: TimelineProvider {
    struct Entry: TimelineEntry { let date: Date }

    func placeholder(in context: Context) -> Entry { Entry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: Date())], policy: .never))
    }
}

struct StartComplicationView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: WS.start)
                        .font(.wktRowTitle)
                        .foregroundStyle(mode == .fullColor ? Color.earthGreen : .primary)
                        .widgetAccentable()
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Start")
                            .font(.wktRowTitle)
                        Text("Wockett")
                            .font(.wktLabel)
                            .foregroundStyle(GlanceTint(mode: mode).secondaryText)
                    }
                    Spacer(minLength: 0)
                }
            case .accessoryCorner:
                Image(systemName: WS.start)
                    .font(.wktRowTitle)
                    .widgetAccentable()
                    .widgetLabel("Start")
            default:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Image(systemName: WS.start)
                            .font(.wktRowTitle)
                            .widgetAccentable()
                        Text("Start")
                            .font(.wktLabel)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Start, opens Wockett")
    }
}

#Preview("Start, circular", as: .accessoryCircular) {
    StartComplication()
} timeline: {
    StartProvider.Entry(date: .now)
}
