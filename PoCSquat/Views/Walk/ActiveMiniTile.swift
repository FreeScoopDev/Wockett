import SwiftUI
import MapKit
import UserNotifications

// MARK: - Active Mini Tile Container
//
// Placed in the root NavigationStack's safe-area inset (SquatCounterApp) so it
// floats persistently above every pushed view while a session is live.

struct ActiveMiniTileContainer: View {
    @Environment(ActiveWalkStore.self) private var walkStore
    @State private var showEndConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            if walkStore.isActive, let session = walkStore.session, let route = walkStore.activeRoute {
                ActiveMiniTile(
                    session: session,
                    route: route,
                    onReopen: { walkStore.requestReopen() },
                    onEnd:   { showEndConfirmation = true }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: walkStore.isActive)
        .confirmationDialog("End Walk?", isPresented: $showEndConfirmation, titleVisibility: .visible) {
            Button("Save & End Walk") {
                guard let session = walkStore.session, let route = walkStore.activeRoute else { return }
                let dist    = session.totalDistanceCovered
                let elapsed = Int(session.elapsedTime)
                // No per-pet distance data here — WalkNavigationView tracks that while mounted.
                // The walk is still saved; pets just won't get distance credit for this session.
                walkStore.buildAndSaveSession(isCommunityRoute: route.isCommunityRoute)
                session.stop()
                walkStore.endSession()
                UNUserNotificationCenter.current().removePendingNotificationRequests(
                    withIdentifiers: (1...12).map { "waterBreak-\($0)" }
                )
                Task { await WalkLiveActivityManager.shared.end(distanceCovered: dist, elapsedSeconds: elapsed) }
            }
            Button("Discard Walk", role: .destructive) {
                guard let session = walkStore.session else { return }
                let dist    = session.totalDistanceCovered
                let elapsed = Int(session.elapsedTime)
                session.stop()
                walkStore.endSession()
                UNUserNotificationCenter.current().removePendingNotificationRequests(
                    withIdentifiers: (1...12).map { "waterBreak-\($0)" }
                )
                Task { await WalkLiveActivityManager.shared.end(distanceCovered: dist, elapsedSeconds: elapsed) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save this walk to your history, or discard it?")
        }
    }
}

// MARK: - Active Mini Tile

struct ActiveMiniTile: View {
    let session: NavigationSessionManager
    let route:   NavigableRoute
    let onReopen: () -> Void
    let onEnd:    () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Tappable area — reopens the full map
            Button(action: onReopen) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.earthGreen.opacity(0.15))
                            .frame(width: 38, height: 38)
                        Image(systemName: route.activityMode.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.earthGreen)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.name)
                            .font(.subheadline.bold())
                            .foregroundColor(.earthCream)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(timeText(session.elapsedTime))
                            Text("·").foregroundColor(.earthMuted)
                            Text(distText(session.totalDistanceCovered))
                        }
                        .font(.caption)
                        .foregroundColor(.earthGreen)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.earthMuted)
                        .padding(.trailing, 4)
                }
                .padding(.leading, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Stop button — separate hit target
            Button(action: onEnd) {
                Image(systemName: "stop.circle.fill")
                    .font(.title2)
                    .foregroundColor(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
        }
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
    }

    private func timeText(_ t: TimeInterval) -> String {
        let s = Int(t); let m = s / 60
        return m < 60 ? "\(m)m \(s % 60)s" : "\(m / 60)h \(m % 60)m"
    }

    private func distText(_ m: Double) -> String {
        MKDistanceFormatter.abbreviated.string(fromDistance: max(0, m))
    }
}
