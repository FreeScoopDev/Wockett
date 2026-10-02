import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

// Widget-local symbol names (WktSymbol is in the app target, unavailable here)
private enum WS {
    static let pauseCircle = "pause.circle.fill"
    static let ecg         = "waveform.path.ecg"
    static let stop        = "stop.fill"
    static let flag        = "flag.fill"
    static let speedometer = "speedometer"
    static let location    = "location.fill"
    static let clock       = "clock.fill"
    static let play        = "play.fill"
    static let pause       = "pause.fill"
}

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

private func fmtPace(_ secsPerKm: Double?, mode: String) -> String {
    guard let p = secsPerKm, p > 0 else { return mode == "cycling" ? "--" : "--:--" }
    let useMetric = Locale.current.measurementSystem != .us
    if mode == "cycling" {
        let kmh = 3600.0 / p
        let value = useMetric ? kmh : kmh / 1.609344
        return String(format: "%.1f %@", value, useMetric ? "km/h" : "mph")
    }
    let adjusted = useMetric ? p : p * 1.60934
    let mins = Int(adjusted) / 60; let secs = Int(adjusted) % 60
    let unit = useMetric ? "/km" : "/mi"
    return String(format: "%d:%02d%@", mins, secs, unit)
}

private func adjustedStart(_ attrs: WalkActivityAttributes, _ state: WalkActivityAttributes.ContentState) -> Date {
    attrs.startDate.addingTimeInterval(state.pausedDuration)
}

private func activityIcon(_ mode: String) -> String {
    switch mode {
    case "running":    return "figure.run"
    case "cycling":    return "figure.outdoor.cycle"
    case "stationary": return "figure.walk.treadmill"
    default:           return "figure.walk"
    }
}

private func activityNoun(_ mode: String) -> String {
    mode == "running" ? "Run" : mode == "cycling" ? "Ride" : "Walk"
}

// MARK: - Color palette (mirrors main app earth palette)

// Colors now come from the shared DesignSystem.swift (earthXXX tokens) --
// this target used to carry its own separately-hardcoded, non-adaptive copy.

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
                    .font(.wktRowTitle)
                    .foregroundColor(.earthGreen)
                Text(attrs.routeName)
                    .font(.wktRowTitle)
                    .foregroundColor(.earthCream)
                    .lineLimit(1)
                Spacer()
                if state.isPaused {
                    Label("Paused", systemImage: WS.pauseCircle)
                        .font(.wktLabel)
                        .foregroundColor(.earthOrange)
                } else {
                    Image(systemName: WS.ecg)
                        .font(.wktLabel)
                        .foregroundColor(.earthGreen)
                }
            }

            // Progress bar
            GeometryReader { geo in
                // WktProgressBar's look (app-only): a capsule on the track.
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.earthTrack)
                        .frame(height: 6)
                    let pct = attrs.totalDistanceMeters > 0
                        ? min(1, state.distanceCoveredMeters / attrs.totalDistanceMeters)
                        : 0
                    Capsule()
                        .fill(Color.earthGreen)
                        .frame(width: geo.size.width * pct, height: 6)
                }
            }
            .frame(height: 6)

            // Stats row
            HStack(spacing: 0) {
                statCell(
                    value: fmtDistance(state.distanceCoveredMeters),
                    label: "Covered",
                    icon: WS.location
                )
                Divider().frame(height: 30).overlay(Color.earthTrack)
                timerStatCell(label: "Elapsed", icon: WS.clock)
                if attrs.totalDistanceMeters > 0 {
                    Divider().frame(height: 30).overlay(Color.earthTrack)
                    statCell(
                        value: fmtDistance(max(0, attrs.totalDistanceMeters - state.distanceCoveredMeters)),
                        label: "Remaining",
                        icon: WS.flag
                    )
                }
                Divider().frame(height: 30).overlay(Color.earthTrack)
                statCell(
                    value: fmtPace(state.paceSecsPerKm, mode: attrs.activityMode),
                    label: attrs.activityMode == "cycling" ? "Speed" : "Pace",
                    icon: WS.speedometer
                )
            }

            // Interactive buttons
            HStack(spacing: 10) {
                // Pause is the green action, as on the session screen; ending
                // is red, the colour of its hold-to-finish button.
                Button(intent: ToggleWalkPauseLiveActivityIntent()) {
                    Label(state.isPaused ? "Resume" : "Pause",
                          systemImage: state.isPaused ? WS.play : WS.pause)
                        .font(.wktLabel)
                }
                .tint(.earthGreenFill)

                Button(intent: EndWalkLiveActivityIntent()) {
                    Label("End \(activityNoun(attrs.activityMode))", systemImage: WS.stop)
                        .font(.wktLabel)
                }
                .tint(.red)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.earthBg)
    }

    private func timerStatCell(label: String, icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.wktBody(11))
                .foregroundColor(.earthGreen)
            Text(timerInterval: adjustedStart(attrs, state)...adjustedStart(attrs, state).addingTimeInterval(86400), pauseTime: state.pauseTime, countsDown: false)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .font(Font.wktRowTitle.monospacedDigit())
                .foregroundColor(.earthCream)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.wktLabel)
                .foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private func statCell(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.wktBody(11))
                .foregroundColor(.earthGreen)
            Text(value)
                .font(Font.wktRowTitle.monospacedDigit())
                .foregroundColor(.earthCream)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.wktLabel)
                .foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Live Activity Widget

struct WocketWalkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WalkActivityAttributes.self) { context in
            WalkLockScreenView(context: context)
                .activityBackgroundTint(Color.earthBg)
                .activitySystemActionForegroundColor(Color.earthGreen)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded (long-press or always-on)
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Image(systemName: activityIcon(context.attributes.activityMode))
                            .font(.wktLabel)
                            .foregroundColor(.earthGreen)
                        Text(timerInterval: adjustedStart(context.attributes, context.state)...adjustedStart(context.attributes, context.state).addingTimeInterval(86400), pauseTime: context.state.pauseTime, countsDown: false)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                            .font(Font.wktSection.monospacedDigit())
                            .foregroundColor(.earthCream)
                        Text("Elapsed")
                            .font(.wktLabel)
                            .foregroundColor(.earthMuted)
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if context.attributes.totalDistanceMeters > 0 {
                            Image(systemName: WS.flag)
                                .font(.wktLabel)
                                .foregroundColor(.earthGreen)
                            let remaining = max(0, context.attributes.totalDistanceMeters - context.state.distanceCoveredMeters)
                            Text(fmtDistance(remaining))
                                .font(Font.wktSection.monospacedDigit())
                                .foregroundColor(.earthCream)
                            Text("Remaining")
                                .font(.wktLabel)
                                .foregroundColor(.earthMuted)
                        } else {
                            Image(systemName: WS.speedometer)
                                .font(.wktLabel)
                                .foregroundColor(.earthGreen)
                            Text(fmtPace(context.state.paceSecsPerKm, mode: context.attributes.activityMode))
                                .font(Font.wktSection.monospacedDigit())
                                .foregroundColor(.earthCream)
                            Text(context.attributes.activityMode == "cycling" ? "Speed" : "Pace")
                                .font(.wktLabel)
                                .foregroundColor(.earthMuted)
                        }
                    }
                    .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.routeName)
                        .font(.wktLabel)
                        .foregroundColor(.earthMuted)
                        .lineLimit(1)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        HStack(spacing: 20) {
                            Label(fmtDistance(context.state.distanceCoveredMeters), systemImage: WS.location)
                                .font(Font.wktRowTitle.monospacedDigit())
                                .foregroundColor(.earthCream)
                            Label(fmtPace(context.state.paceSecsPerKm, mode: context.attributes.activityMode), systemImage: WS.speedometer)
                                .font(Font.wktRowTitle.monospacedDigit())
                                .foregroundColor(context.state.isPaused ? .earthOrange : .earthCream)
                            if context.state.isPaused {
                                Label("Paused", systemImage: WS.pauseCircle)
                                    .font(.wktLabel)
                                    .foregroundColor(.earthOrange)
                            }
                        }

                        HStack(spacing: 10) {
                            Button(intent: ToggleWalkPauseLiveActivityIntent()) {
                                Label(context.state.isPaused ? "Resume" : "Pause",
                                      systemImage: context.state.isPaused ? WS.play : WS.pause)
                                    .font(.wktLabel)
                            }
                            .tint(.earthGreenFill)

                            Button(intent: EndWalkLiveActivityIntent()) {
                                Label("End \(activityNoun(context.attributes.activityMode))", systemImage: WS.stop)
                                    .font(.wktLabel)
                            }
                            .tint(.red)
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
                    .font(.wktLabel)
                    .foregroundColor(.earthGreen)

            } compactTrailing: {
                // Compact pill — right side: distance covered
                Text(fmtDistance(context.state.distanceCoveredMeters))
                    .font(Font.wktLabel.monospacedDigit())
                    .foregroundColor(.earthCream)
                    .minimumScaleFactor(0.7)

            } minimal: {
                // Minimal (when two activities compete): just the icon
                Image(systemName: activityIcon(context.attributes.activityMode))
                    .font(.wktLabel)
                    .foregroundColor(.earthGreen)
            }
            .keylineTint(Color.earthGreen)
            .widgetURL(URL(string: "wockett://walk"))
        }
    }
}
