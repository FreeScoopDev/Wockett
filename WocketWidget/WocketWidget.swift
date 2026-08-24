import WidgetKit
import SwiftUI

// MARK: - App Group keys (must match BackgroundTaskManager + WidgetDataWriter)

private let appGroup = "group.com.scoops.wockett"
private enum WKey {
    static let steps    = "wkt_widget_steps"
    static let goal     = "wkt_widget_goal"
    static let streak   = "wkt_widget_streak"
    static let distance = "wkt_widget_distanceMeters"
    static let refresh  = "wkt_widget_lastRefresh"
}

// MARK: - Earth palette (mirrored from main app; can't import main target)

private extension Color {
    static let wktGreen  = Color(red: 0.28, green: 0.54, blue: 0.36)
    static let wktCream  = Color(red: 0.94, green: 0.91, blue: 0.85)
    static let wktMuted  = Color(red: 0.55, green: 0.55, blue: 0.52)
    static let wktBg     = Color(red: 0.10, green: 0.12, blue: 0.11)
    static let wktCard   = Color(red: 0.15, green: 0.17, blue: 0.16)
    static let wktOrange = Color(red: 0.85, green: 0.45, blue: 0.20)
}

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
        let nextHour = Calendar.current.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime)!
        completion(Timeline(entries: [entry], policy: .after(nextHour)))
    }

    private func currentEntry() -> StepEntry {
        let ud      = UserDefaults(suiteName: appGroup)
        let steps   = ud?.integer(forKey: WKey.steps)    ?? 0
        let goal    = ud?.integer(forKey: WKey.goal)     ?? 10_000
        let streak  = ud?.integer(forKey: WKey.streak)   ?? 0
        let dist    = ud?.double(forKey: WKey.distance)  ?? 0
        let refresh = ud?.object(forKey: WKey.refresh)   as? Date
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
        ZStack {
            Circle()
                .stroke(Color.wktGreen.opacity(0.18), lineWidth: 10)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        colors: [Color.wktGreen.opacity(0.7), Color.wktGreen],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270 * progress - 90)
                    ),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)
            VStack(spacing: 1) {
                Text(steps.formatted())
                    .font(.system(size: fontSize, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(.wktCream)
                Text("steps")
                    .font(.system(size: fontSize * 0.38, weight: .medium))
                    .foregroundColor(.wktMuted)
            }
        }
    }
}

// MARK: - Small Widget

private struct SmallStepView: View {
    let entry: StepEntry

    var body: some View {
        ZStack {
            Color.wktBg
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "figure.walk")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.wktGreen)
                    Text("Wockett")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.wktMuted)
                    Spacer()
                    if entry.streak > 0 {
                        HStack(spacing: 2) {
                            Text("\(entry.streak)")
                                .font(.caption2.bold())
                            Text("🔥")
                                .font(.system(size: 9))
                        }
                        .foregroundColor(.wktOrange)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)

                StepRingView(progress: entry.progress, steps: entry.steps, fontSize: 20)
                    .padding(.horizontal, 18)

                Text("of \(entry.goal.formatted())")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(.wktMuted)
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
            Color.wktBg
            HStack(spacing: 0) {
                // Ring on the left
                StepRingView(progress: entry.progress, steps: entry.steps, fontSize: 22)
                    .frame(width: 120)
                    .padding(.leading, 16)

                // Stats on the right
                VStack(alignment: .leading, spacing: 10) {
                    statRow(icon: "target", label: "Goal", value: entry.goal.formatted())
                    statRow(icon: "ruler", label: "Distance", value: entry.distanceText)
                    if entry.streak > 0 {
                        statRow(icon: "flame.fill", label: "Streak",
                                value: "\(entry.streak) day\(entry.streak == 1 ? "" : "s")",
                                valueColor: .wktOrange)
                    }
                    let pct = Int(entry.progress * 100)
                    statRow(icon: "percent", label: "Progress", value: "\(pct)%",
                            valueColor: entry.progress >= 1 ? .wktGreen : .wktCream)
                }
                .padding(.leading, 16)
                .padding(.trailing, 14)

                Spacer()
            }
            .padding(.vertical, 14)
        }
    }

    private func statRow(icon: String, label: String, value: String,
                         valueColor: Color = .wktCream) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.wktGreen)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.wktMuted)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(valueColor)
        }
    }
}

// MARK: - Accessory Circular (lock screen / watch face)

private struct CircularStepView: View {
    let entry: StepEntry

    var body: some View {
        Gauge(value: entry.progress) {
            Image(systemName: "figure.walk")
        } currentValueLabel: {
            Text(shortSteps(entry.steps))
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(.wktGreen)
    }

    private func shortSteps(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

// MARK: - Widget Definition

struct WocketStepWidget: Widget {
    let kind = "WocketStepWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StepWidgetProvider()) { entry in
            WocketStepWidgetView(entry: entry)
                .containerBackground(Color.wktBg, for: .widget)
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
