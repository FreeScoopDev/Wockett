import ActivityKit
import Foundation

// MARK: - WalkLiveActivityManager
//
// Started when a guided walk begins, updated on each significant distance/pace
// change, and ended when the walk completes or is stopped.

@MainActor
final class WalkLiveActivityManager {
    static let shared = WalkLiveActivityManager()

    private var activity: Activity<WalkActivityAttributes>?

    private init() {}

    // MARK: - Lifecycle

    /// Ends every Live Activity the system knows about for this app, including
    /// orphans from a previous process that our in-memory `activity` reference
    /// no longer points to. Safe to call when no activities are running.
    func endAllActivities() async {
        for orphan in Activity<WalkActivityAttributes>.activities {
            await orphan.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
    }

    func start(routeName: String, totalDistanceMeters: Double, activityMode: String, startDate: Date) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Reap any orphan activities left from a previous process before starting a new one.
        await endAllActivities()

        let attributes = WalkActivityAttributes(
            routeName: routeName,
            totalDistanceMeters: totalDistanceMeters,
            activityMode: activityMode,
            startDate: startDate
        )
        let initialState = WalkActivityAttributes.ContentState(
            distanceCoveredMeters: 0,
            elapsedSeconds: 0,
            isPaused: false,
            paceSecsPerKm: nil,
            pausedDuration: 0,
            pauseTime: nil
        )
        let content = ActivityContent(state: initialState, staleDate: nil)
        activity = try? Activity.request(attributes: attributes, content: content)
    }

    func update(distanceCovered: Double, elapsedSeconds: Int,
                isPaused: Bool, paceSecsPerKm: Double?,
                pausedDuration: Double, pauseTime: Date?) async {
        guard let activity else { return }
        let state = WalkActivityAttributes.ContentState(
            distanceCoveredMeters: distanceCovered,
            elapsedSeconds: elapsedSeconds,
            isPaused: isPaused,
            paceSecsPerKm: paceSecsPerKm,
            pausedDuration: pausedDuration,
            pauseTime: pauseTime
        )
        let content = ActivityContent(state: state, staleDate: nil)
        await activity.update(content)
    }

    func end(distanceCovered: Double, elapsedSeconds: Int, pausedDuration: Double) async {
        let finalState = WalkActivityAttributes.ContentState(
            distanceCoveredMeters: distanceCovered,
            elapsedSeconds: elapsedSeconds,
            isPaused: false,
            paceSecsPerKm: nil,
            pausedDuration: pausedDuration,
            pauseTime: Date()   // freeze the display — a finished walk's summary shouldn't keep ticking
        )
        let content = ActivityContent(state: finalState, staleDate: .now)
        let dismissal: ActivityUIDismissalPolicy = .after(.now.addingTimeInterval(10))
        // End our tracked reference first, then sweep any strays the system still knows about.
        if let activity {
            await activity.end(content, dismissalPolicy: dismissal)
        }
        for stray in Activity<WalkActivityAttributes>.activities {
            await stray.end(content, dismissalPolicy: dismissal)
        }
        self.activity = nil
    }
}
