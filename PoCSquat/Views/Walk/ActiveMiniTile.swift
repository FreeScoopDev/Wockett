import SwiftUI
import MapKit
import UserNotifications

// MARK: - Active Mini Tile Container
//
// Content for .tabViewBottomAccessory(isEnabled: walkStore.isActive).
// The system capsule handles background, shape, and show/hide animation.

struct ActiveMiniTileContainer: View {
    @Environment(ActiveWalkStore.self) private var walkStore
    @EnvironmentObject private var tabRouter: TabRouter
    @State private var showEndConfirmation = false

    var body: some View {
        Group {
            if let session = walkStore.session, let route = walkStore.activeRoute {
                ActiveMiniTile(
                    session: session,
                    route: route,
                    onReopen: {
                        tabRouter.selected = .home
                        Task { @MainActor in walkStore.requestReopen() }
                    },
                    onEnd: { showEndConfirmation = true }
                )
            }
        }
        .confirmationDialog("End \(walkStore.activeRoute?.activityMode.sessionLabel ?? "Walk")?", isPresented: $showEndConfirmation, titleVisibility: .visible) {
            Button("Save & End \(walkStore.activeRoute?.activityMode.sessionLabel ?? "Walk")") {
                guard walkStore.session != nil else { return }
                walkStore.saveAndEndActiveSession()
            }
            Button("Discard \(walkStore.activeRoute?.activityMode.sessionLabel ?? "Walk")", role: .destructive) {
                guard let session = walkStore.session else { return }
                let dist          = session.totalDistanceCovered
                let elapsed       = Int(session.elapsedTime)
                let pausedDuration = session.totalPausedDuration
                session.discardWorkoutSession()
                session.stop()
                walkStore.endSession()
                UNUserNotificationCenter.current().removePendingNotificationRequests(
                    withIdentifiers: (1...12).map { "waterBreak-\($0)" }
                )
                Task { await WalkLiveActivityManager.shared.end(distanceCovered: dist, elapsedSeconds: elapsed, pausedDuration: pausedDuration) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save this \(walkStore.activeRoute?.activityMode.noun ?? "walk") to your history, or discard it?")
        }
    }
}

// MARK: - Active Mini Tile
//
// Renders compact (inline — tab bar minimized) or expanded (normal) form.
// The system capsule provides the background and shape; no chrome here.

struct ActiveMiniTile: View {
    let session: NavigationSessionManager
    let route:   NavigableRoute
    let onReopen: () -> Void
    let onEnd:    () -> Void

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if placement == .inline {
            compactView
        } else {
            expandedView
        }
    }

    // MARK: - Compact (inline — tab bar minimized)

    private var compactView: some View {
        Button(action: onReopen) {
            HStack(spacing: 8) {
                Image(wkt: route.activityMode.wktSymbol)
                    .wktIcon(.inline, tint: .earthGreen)
                Text(distText(session.totalDistanceCovered))
                    .font(.wktBody(13))
                    .foregroundColor(.earthCream)
                Text("·")
                    .foregroundColor(.earthMuted)
                Text(timeText(session.elapsedTime))
                    .font(.wktBody(13))
                    .foregroundColor(.earthGreen)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Active \(route.activityMode.noun): \(distText(session.totalDistanceCovered)), \(timeText(session.elapsedTime))")
    }

    // MARK: - Expanded (normal — tab bar visible)

    private var expandedView: some View {
        HStack(spacing: 0) {
            Button(action: onReopen) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.earthGreen.opacity(0.15))
                            .frame(width: 38, height: 38)
                        Image(wkt: route.activityMode.wktSymbol)
                            .wktIcon(.row, tint: .earthGreen)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.name)
                            .font(.wktHeading(14))
                            .foregroundColor(.earthCream)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(timeText(session.elapsedTime))
                            Text("·").foregroundColor(.earthMuted)
                            Text(distText(session.totalDistanceCovered))
                        }
                        .font(.wktBody(12))
                        .foregroundColor(.earthGreen)
                    }

                    Spacer(minLength: 8)

                    Image(wkt: .chevronUp)
                        .wktIcon(.inline, tint: .earthMuted)
                        .padding(.trailing, 4)
                }
                .padding(.leading, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Return to \(route.name)")
            .accessibilityHint("Opens the active session")

            Button(action: onEnd) {
                Image(wkt: .stop)
                    .wktIcon(.tab, tint: .red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .accessibilityLabel("End \(route.activityMode.noun)")
        }
    }

    private func timeText(_ t: TimeInterval) -> String {
        let s = Int(t); let m = s / 60
        return m < 60 ? "\(m)m \(s % 60)s" : "\(m / 60)h \(m % 60)m"
    }

    private func distText(_ m: Double) -> String {
        MKDistanceFormatter.abbreviated.string(fromDistance: max(0, m))
    }
}
