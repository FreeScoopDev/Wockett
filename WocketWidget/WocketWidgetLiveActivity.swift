import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Formatting helpers (widget-local, no access to main app)

private func fmtDistance(_ meters: Double) -> String {
    let useMetric = Locale.current.measurementSystem != .us
    if useMetric {
        return meters >= 1000
            ? String(format: "%.2f km", meters / 1000)
            : String(format: "%.0f m", meters)
    } else {
        let mi = meters / 1609.34
        return mi >= 0.1
            ? String(format: "%.2f mi", mi)
            : String(format: "%.0f ft", meters * 3.281)
    }
}

private func fmtTime(_ seconds: Int) -> String {
    let m = seconds / 60, s = seconds % 60
    return m >= 60
        ? String(format: "%d:%02d:%02d", m / 60, m % 60, s)
        : String(format: "%d:%02d", m, s)
}

private func fmtPace(_ secsPerKm: Double?) -> String {
    guard let p = secsPerKm, p > 0 else { return "--:--" }
    let useMetric = Locale.current.measurementSystem != .us
    let adjusted  = useMetric ? p : p * 1.60934
    let mins = Int(adjusted) / 60; let secs = Int(adjusted) % 60
    let unit = useMetric ? "/km" : "/mi"
    return String(format: "%d:%02d%@", mins, secs, unit)
}

private func adjustedStart(_ attrs: WalkActivityAttributes, _ state: WalkActivityAttributes.ContentState) -> Date {
    attrs.startDate.addingTimeInterval(state.pausedDuration)
}

private func activityIcon(_ mode: String) -> String {
    switch mode {
    case "cycling":    return "bicycle"
    case "stationary": return "figure.walk.motion"
    default:           return "figure.walk"
    }
}

// MARK: - Color palette (mirrors main app earth palette)

private extension Color {
    static let wktGreen  = Color(red: 0.28, green: 0.54, blue: 0.36)
    static let wktCream  = Color(red: 0.94, green: 0.91, blue: 0.85)
    static let wktMuted  = Color(red: 0.55, green: 0.55, blue: 0.52)
    static let wktBg     = Color(red: 0.10, green: 0.12, blue: 0.11)
    static let wktOrange = Color(red: 0.85, green: 0.45, blue: 0.20)
}

// MARK: - Lock Screen / StandBy Banner

private struct WalkLockScreenView: View {
    let context: ActivityViewContext<WalkActivityAttributes>

    private var state: WalkActivityAttributes.ContentState { context.state }
    private var attrs: WalkActivityAttributes { context.attributes }

    var body: some View {
        VStack(spacing: 10) {
            // Header
            HStack {
                Image(systemName: activityIcon(attrs.activityMode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.wktGreen)
                Text(attrs.routeName)
                    .font(.subheadline.bold())
                    .foregroundColor(.wktCream)
                    .lineLimit(1)
                Spacer()
                if state.isPaused {
                    Label("Paused", systemImage: "pause.circle.fill")
                        .font(.caption.bold())
                        .foregroundColor(.wktOrange)
                } else {
                    Image(systemName: "waveform.path.ecg")
                        .font(.caption)
                        .foregroundColor(.wktGreen)
                }
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 6)
                    let pct = attrs.totalDistanceMeters > 0
                        ? min(1, state.distanceCoveredMeters / attrs.totalDistanceMeters)
                        : 0
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.wktGreen)
                        .frame(width: geo.size.width * pct, height: 6)
                }
            }
            .frame(height: 6)

            // Stats row
            HStack(spacing: 0) {
                statCell(
                    value: fmtDistance(state.distanceCoveredMeters),
                    label: "covered",
                    icon: "location.fill"
                )
                Divider().frame(height: 30).overlay(Color.white.opacity(0.15))
                timerStatCell(label: "elapsed", icon: "clock.fill")
                Divider().frame(height: 30).overlay(Color.white.opacity(0.15))
                statCell(
                    value: fmtDistance(max(0, attrs.totalDistanceMeters - state.distanceCoveredMeters)),
                    label: "remaining",
                    icon: "flag.fill"
                )
                Divider().frame(height: 30).overlay(Color.white.opacity(0.15))
                statCell(
                    value: fmtPace(state.paceSecsPerKm),
                    label: "pace",
                    icon: "speedometer"
                )
            }

            // Interactive buttons
            HStack(spacing: 10) {
                Button(intent: ToggleWalkPauseLiveActivityIntent()) {
                    Label(state.isPaused ? "Resume" : "Pause",
                          systemImage: state.isPaused ? "play.fill" : "pause.fill")
                        .font(.caption.bold())
                }
                .tint(.wktOrange)

                Button(intent: EndWalkLiveActivityIntent()) {
                    Label("End Walk", systemImage: "stop.fill")
                        .font(.caption.bold())
                }
                .tint(.wktGreen)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.wktBg)
    }

    private func timerStatCell(label: String, icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.wktGreen)
            Text(timerInterval: adjustedStart(attrs, state)...adjustedStart(attrs, state).addingTimeInterval(86400), pauseTime: state.pauseTime, countsDown: false)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(.wktCream)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.wktMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private func statCell(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.wktGreen)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(.wktCream)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.wktMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Live Activity Widget

struct WocketWalkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WalkActivityAttributes.self) { context in
            WalkLockScreenView(context: context)
                .activityBackgroundTint(Color.wktBg)
                .activitySystemActionForegroundColor(Color.wktGreen)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded (long-press or always-on)
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Image(systemName: activityIcon(context.attributes.activityMode))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.wktGreen)
                        Text(timerInterval: adjustedStart(context.attributes, context.state)...adjustedStart(context.attributes, context.state).addingTimeInterval(86400), pauseTime: context.state.pauseTime, countsDown: false)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundColor(.wktCream)
                        Text("elapsed")
                            .font(.system(size: 9))
                            .foregroundColor(.wktMuted)
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Image(systemName: "flag.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.wktGreen)
                        let remaining = max(0, context.attributes.totalDistanceMeters - context.state.distanceCoveredMeters)
                        Text(fmtDistance(remaining))
                            .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundColor(.wktCream)
                        Text("remaining")
                            .font(.system(size: 9))
                            .foregroundColor(.wktMuted)
                    }
                    .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.routeName)
                        .font(.caption.bold())
                        .foregroundColor(.wktMuted)
                        .lineLimit(1)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        HStack(spacing: 20) {
                            Label(fmtDistance(context.state.distanceCoveredMeters), systemImage: "location.fill")
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundColor(.wktCream)
                            Label(fmtPace(context.state.paceSecsPerKm), systemImage: "speedometer")
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundColor(context.state.isPaused ? .wktOrange : .wktCream)
                            if context.state.isPaused {
                                Label("Paused", systemImage: "pause.circle.fill")
                                    .font(.caption.bold())
                                    .foregroundColor(.wktOrange)
                            }
                        }

                        HStack(spacing: 10) {
                            Button(intent: ToggleWalkPauseLiveActivityIntent()) {
                                Label(context.state.isPaused ? "Resume" : "Pause",
                                      systemImage: context.state.isPaused ? "play.fill" : "pause.fill")
                                    .font(.caption.bold())
                            }
                            .tint(.wktOrange)

                            Button(intent: EndWalkLiveActivityIntent()) {
                                Label("End Walk", systemImage: "stop.fill")
                                    .font(.caption.bold())
                            }
                            .tint(.wktGreen)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                    }
                    .padding(.bottom, 6)
                }

            } compactLeading: {
                // Compact pill — left side: icon
                Image(systemName: activityIcon(context.attributes.activityMode))
                    .font(.caption.weight(.bold))
                    .foregroundColor(.wktGreen)

            } compactTrailing: {
                // Compact pill — right side: distance covered
                Text(fmtDistance(context.state.distanceCoveredMeters))
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(.wktCream)
                    .minimumScaleFactor(0.7)

            } minimal: {
                // Minimal (when two activities compete): just the icon
                Image(systemName: activityIcon(context.attributes.activityMode))
                    .font(.caption.weight(.bold))
                    .foregroundColor(.wktGreen)
            }
            .keylineTint(Color.wktGreen)
            .widgetURL(URL(string: "wockett://walk"))
        }
    }
}
