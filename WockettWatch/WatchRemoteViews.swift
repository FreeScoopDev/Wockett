import SwiftUI

/// Picks the screen `WatchRemoteDisplay` says to show. The views only draw;
/// what to show and when lives in WatchWalkLink.swift.
struct WatchRootView: View {
    let model: WatchSessionModel

    var body: some View {
        Group {
            switch model.display.screen {
            case .idle, .starting:
                WatchIdleView(model: model)
            case .live:
                if let state = model.display.state { WatchLiveView(model: model, state: state) }
            case .summary:
                if let ended = model.display.summary { WatchSummaryView(model: model, ended: ended) }
            }
        }
        .background(Color.earthBg)
    }
}

// MARK: - Idle

/// The four activities and Start.
struct WatchIdleView: View {
    @Bindable var model: WatchSessionModel

    var body: some View {
        let starting = model.display.screen == .starting
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: WktSpacing.betweenCards / 2) {
                    // Notices first, so the screen can show them at once.
                    Group {
                        if model.display.needsPhone {
                            WatchNote(symbol: WS.iPhone, text: "Open Wockett on your iPhone to start.")
                        }
                        if !model.isReachable {
                            WatchNote(symbol: WS.notReachable, text: "iPhone not reachable")
                        }
                    }
                    .id(Self.noticeID)

                    ForEach(WatchActivity.allCases, id: \.self) { activity in
                        activityRow(activity)
                    }
                    Button {
                        model.start()
                    } label: {
                        HStack(spacing: 6) {
                            if starting { ProgressView().frame(width: 18, height: 18) }
                            Text(starting ? "Starting…" : "Start")
                                .font(.wktRowTitle)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .tint(.earthGreen)
                    .disabled(starting || !model.controlsEnabled)
                    .accessibilityIdentifier("watch.start")
                }
            }
            // Start is at the bottom; a refusal scrolls up to say why.
            .onChange(of: model.display.needsPhone) { _, needsPhone in
                if needsPhone { withAnimation { proxy.scrollTo(Self.noticeID, anchor: .top) } }
            }
        }
        .navigationTitle("Wockett")
    }

    private static let noticeID = "watch.idle.notice"

    private func activityRow(_ activity: WatchActivity) -> some View {
        let selected = model.selectedActivity == activity
        return Button {
            model.selectedActivity = activity
        } label: {
            Label(activity.displayName, systemImage: WS.icon(for: activity))
                .font(.wktBodyText)
                .foregroundStyle(selected ? Color.earthBg : Color.earthCream)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(selected ? .earthGreen : .earthRaised)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Live

struct WatchLiveView: View {
    let model: WatchSessionModel
    let state: WatchWalkState
    @State private var confirmFinish = false

    private var paused: Bool { state.phase == .paused }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WktSpacing.betweenCards / 2) {
                HStack(spacing: 6) {
                    Image(systemName: WS.icon(for: state.mode))
                        .foregroundStyle(Color.earthGreen)
                    Text(paused ? "Paused" : state.mode.title)
                        .font(.wktRowTitle)
                        .foregroundStyle(paused ? Color.earthOrange : Color.earthCream)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(paused ? "\(state.mode.title) paused" : "\(state.mode.title) in progress")

                if let start = state.timerStart {
                    Text(timerInterval: start...start.addingTimeInterval(7 * 86400),
                         pauseTime: state.pausedAt, countsDown: false)
                        .font(Font.wktSection.monospacedDigit())
                        .foregroundStyle(paused ? Color.earthMuted : Color.earthCream)
                }
                if let meters = state.distanceMeters {
                    metric(WatchWalkFormat.distance(meters, usesMiles: state.usesMiles), label: "distance")
                }
                if state.mode.showsPace {
                    metric(WatchWalkFormat.pace(secsPerKm: state.currentPaceSecsPerKm, usesMiles: state.usesMiles),
                           label: "pace")
                    metric(WatchWalkFormat.pace(secsPerKm: state.averagePaceSecsPerKm, usesMiles: state.usesMiles),
                           label: "avg pace")
                } else if state.mode.showsSpeed {
                    metric(WatchWalkFormat.speed(metersPerSecond: state.averageSpeedMetersPerSecond,
                                                 usesMiles: state.usesMiles), label: "speed")
                }

                if !model.isReachable {
                    WatchNote(symbol: WS.notReachable, text: "iPhone not reachable")
                }
                if state.controllable {
                    controls
                } else {
                    WatchNote(symbol: WS.iPhone, text: "Finish your \(state.mode.noun) on your iPhone.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Finish your \(state.mode.noun)?", isPresented: $confirmFinish) {
            Button("Finish and save") { model.finish() }
            Button("Keep going", role: .cancel) {}
        }
    }

    private var controls: some View {
        VStack(spacing: WktSpacing.betweenCards / 2) {
            Button {
                model.togglePause()
            } label: {
                Label(paused ? "Resume" : "Pause", systemImage: paused ? WS.resume : WS.pause)
                    .font(.wktRowTitle)
                    .frame(maxWidth: .infinity)
            }
            .tint(paused ? .earthGreen : .earthOrange)
            .accessibilityIdentifier("watch.pauseResume")

            WatchHoldToFinishButton(noun: state.mode.noun) { confirmFinish = true }
                .accessibilityIdentifier("watch.finish")
        }
        .disabled(!model.controlsEnabled)
    }

    private func metric(_ value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(value)
                .font(Font.wktRowTitle.monospacedDigit())
                .foregroundStyle(Color.earthCream)
            Spacer(minLength: 4)
            Text(label)
                .font(.wktLabel)
                .foregroundStyle(Color.earthMuted)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Finish is a press and hold of about a second, as on the phone, then a
/// question, so a brush of the wrist cannot end a walk.
struct WatchHoldToFinishButton: View {
    let noun: String
    let onHeld: () -> Void
    @State private var pressing = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.earthRaised)
            GeometryReader { geo in
                Capsule()
                    .fill(Color.earthOrange.opacity(0.6))
                    .frame(width: pressing ? geo.size.width : 0)
                    .animation(pressing ? .linear(duration: 1) : .easeOut(duration: 0.15), value: pressing)
            }
            Label("Hold to finish", systemImage: WS.finish)
                .font(.wktBodyText)
                .foregroundStyle(isEnabled ? Color.earthCream : Color.earthMuted)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 40)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: 1, perform: onHeld) { pressing = $0 && isEnabled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Finish \(noun)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if isEnabled { onHeld() } }
    }
}

// MARK: - Summary

struct WatchSummaryView: View {
    let model: WatchSessionModel
    let ended: WatchWalkState

    var body: some View {
        ScrollView {
            VStack(spacing: WktSpacing.betweenCards / 2) {
                Image(systemName: WS.icon(for: ended.mode))
                    .font(.wktSection)
                    .foregroundStyle(Color.earthGreen)
                Text("\(ended.mode.title) saved")
                    .font(.wktRowTitle)
                    .foregroundStyle(Color.earthCream)
                if let summary = ended.summary {
                    Text(WatchWalkFormat.distance(summary.distanceMeters, usesMiles: ended.usesMiles))
                        .font(Font.wktSection.monospacedDigit())
                        .foregroundStyle(Color.earthCream)
                    Text(WatchWalkFormat.duration(summary.movingSeconds))
                        .font(Font.wktRowTitle.monospacedDigit())
                        .foregroundStyle(Color.earthMuted)
                }
                Text("The details are on your iPhone.")
                    .font(.wktLabel)
                    .foregroundStyle(Color.earthMuted)
                    .multilineTextAlignment(.center)
                Button {
                    model.dismissSummary()
                } label: {
                    Label("Done", systemImage: WS.done)
                        .font(.wktRowTitle)
                        .frame(maxWidth: .infinity)
                }
                .tint(.earthGreen)
                .accessibilityIdentifier("watch.summaryDone")
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Pieces

/// A one-line notice with its symbol.
struct WatchNote: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.wktLabel)
                .foregroundStyle(Color.earthCream)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Color.earthOrange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
