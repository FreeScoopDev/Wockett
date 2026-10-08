import WidgetKit
import SwiftUI

// Widget-local symbol names (WktSymbol is in the app target, unavailable here)
private enum WS {
    static let walk    = "figure.walk"
    static let flame   = "flame.fill"
    static let target  = "target"
    static let ruler   = "ruler"
    static let percent = "percent"
}

// App group keys come from AppGroup.swift, compiled into both targets, so
// the app's writer (WidgetSnapshot) and this reader cannot drift.
private typealias WKey = AppGroup.WidgetKey

// Colors now come from the shared DesignSystem.swift (earthXXX tokens) --
// this target used to carry its own separately-hardcoded, non-adaptive copy.

// MARK: - Timeline Entry

struct StepEntry: TimelineEntry {
    let date: Date
    let steps: Int
    let goal: Int
    let streak: Int
    let distanceMeters: Double
    let lastRefresh: Date?

    var progress: Double { min(1.0, Double(steps) / Double(max(1, goal))) }

    var distanceText: String {
        let useMetric = Locale.current.measurementSystem != .us
        if useMetric {
            let km = distanceMeters / 1000
            return km >= 1 ? String(format: "%.1f km", km) : "\(Int(distanceMeters)) m"
        } else {
            let mi = distanceMeters / 1609.34
            return mi >= 0.1 ? String(format: "%.1f mi", mi) : String(format: "%.0f ft", distanceMeters * 3.281)
        }
    }

    static var placeholder: StepEntry {
        StepEntry(date: .now, steps: 7234, goal: 10_000, streak: 5,
                  distanceMeters: 5_412, lastRefresh: nil)
    }
}

// MARK: - Provider

struct StepWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> StepEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (StepEntry) -> Void) {
        completion(context.isPreview ? .placeholder : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StepEntry>) -> Void) {
        let entry = currentEntry()
        // Refresh at the start of the next hour (or sooner if BGAppRefresh fires)
        let nextHour = Calendar.current.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(nextHour)))
    }

    private func currentEntry() -> StepEntry {
        let ud      = AppGroup.defaults
        let steps   = ud?.integer(forKey: WKey.steps)    ?? 0
        let goal    = ud?.integer(forKey: WKey.goal)     ?? 10_000
        let streak  = ud?.integer(forKey: WKey.streak)   ?? 0
        let dist    = ud?.double(forKey: WKey.distanceMeters)  ?? 0
        let refresh = ud?.object(forKey: WKey.lastRefresh)   as? Date
        return StepEntry(date: .now, steps: steps, goal: goal,
                         streak: streak, distanceMeters: dist, lastRefresh: refresh)
    }
}

// MARK: - Step Ring (shared between sizes)

private struct StepRingView: View {
    let progress: Double
    let steps: Int
    let fontSize: CGFloat

    var body: some View {
        // The same ring as Home's Today card (WktGoalRing, app-only): the
        // user's own goal is orange on the track, not green.
        ZStack {
            Circle()
                .stroke(Color.earthTrack, lineWidth: 10)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.earthOrange, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)
            VStack(spacing: 1) {
                Text(steps.formatted())
                    .font(Font.wktHeading(fontSize).monospacedDigit())
                    .foregroundColor(.earthCream)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("steps")
                    .font(.wktLabel)
                    .foregroundColor(.earthMuted)
            }
            .padding(12)
        }
    }
}

// MARK: - Small Widget

private struct SmallStepView: View {
    let entry: StepEntry

    var body: some View {
        ZStack {
            Color.earthBg
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: WS.walk)
                        .font(.wktLabel)
                        .foregroundColor(.earthGreen)
                    Text("Today")
                        .font(.wktLabel)
                        .foregroundColor(.earthCream)
                    Spacer()
                    if entry.streak > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: WS.flame)
                            Text("\(entry.streak)")
                        }
                        .font(.wktLabel)
                        .foregroundColor(.earthOrange)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(entry.streak)-day streak")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)

                StepRingView(progress: entry.progress, steps: entry.steps, fontSize: 20)
                    .padding(.horizontal, 18)

                Text("of \(entry.goal.formatted())")
                    .font(.wktLabel)
                    .foregroundColor(.earthMuted)
                    .padding(.bottom, 12)
            }
        }
    }
}

// MARK: - Medium Widget

private struct MediumStepView: View {
    let entry: StepEntry

    var body: some View {
        ZStack {
            Color.earthBg
            HStack(spacing: 0) {
                // Ring on the left
                StepRingView(progress: entry.progress, steps: entry.steps, fontSize: 22)
                    .frame(width: 120)
                    .padding(.leading, 16)

                // Stats on the right
                VStack(alignment: .leading, spacing: 10) {
                    statRow(icon: WS.target, label: "Goal", value: entry.goal.formatted())
                    statRow(icon: WS.ruler, label: "Distance", value: entry.distanceText)
                    if entry.streak > 0 {
                        statRow(icon: WS.flame, label: "Streak",
                                value: "\(entry.streak) day\(entry.streak == 1 ? "" : "s")",
                                valueColor: .earthOrange)
                    }
                    let pct = WktPercent.value(entry.progress)
                    statRow(icon: WS.percent, label: "Progress", value: "\(pct)%",
                            valueColor: entry.progress >= 1 ? .earthGreen : .earthCream)
                }
                .padding(.leading, 16)
                .padding(.trailing, 14)

                Spacer()
            }
            .padding(.vertical, 14)
        }
    }

    private func statRow(icon: String, label: String, value: String,
                         valueColor: Color = .earthCream) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.wktLabel)
                .foregroundColor(.earthGreen)
                .frame(width: 16)
            Text(label)
                .font(.wktLabel)
                .foregroundColor(.earthMuted)
            Spacer()
            Text(value)
                .font(Font.wktHeading(14).monospacedDigit())
                .foregroundColor(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

// MARK: - Accessory Circular (lock screen / watch face)

private struct CircularStepView: View {
    let entry: StepEntry

    var body: some View {
        Gauge(value: entry.progress) {
            Image(systemName: WS.walk)
        } currentValueLabel: {
            Text(shortSteps(entry.steps))
                .font(.wktBody(11))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(.earthGreen)
    }

    private func shortSteps(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

// MARK: - Widget Definition

struct WocketStepWidget: Widget {
    let kind = AppGroup.stepWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StepWidgetProvider()) { entry in
            WocketStepWidgetView(entry: entry)
                .containerBackground(Color.earthBg, for: .widget)
        }
        .configurationDisplayName("Daily Steps")
        .description("Track your step goal and streak at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
        .contentMarginsDisabled()
    }
}

struct WocketStepWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: StepEntry

    var body: some View {
        switch family {
        case .systemSmall:     SmallStepView(entry: entry)
        case .systemMedium:    MediumStepView(entry: entry)
        case .accessoryCircular: CircularStepView(entry: entry)
        default:               SmallStepView(entry: entry)
        }
    }
}
