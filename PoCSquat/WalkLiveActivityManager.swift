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

    func start(routeName: String, totalDistanceMeters: Double, activityMode: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activity == nil else { return }

        let attributes = WalkActivityAttributes(
            routeName: routeName,
            totalDistanceMeters: totalDistanceMeters,
            activityMode: activityMode
        )
        let initialState = WalkActivityAttributes.ContentState(
            distanceCoveredMeters: 0,
            elapsedSeconds: 0,
            isPaused: false,
            paceSecsPerKm: nil
        )
        let content = ActivityContent(state: initialState, staleDate: nil)
        activity = try? Activity.request(attributes: attributes, content: content)
    }

    func update(distanceCovered: Double, elapsedSeconds: Int,
                isPaused: Bool, paceSecsPerKm: Double?) async {
        guard let activity else { return }
        let state = WalkActivityAttributes.ContentState(
            distanceCoveredMeters: distanceCovered,
            elapsedSeconds: elapsedSeconds,
            isPaused: isPaused,
            paceSecsPerKm: paceSecsPerKm
        )
        let content = ActivityContent(state: state, staleDate: nil)
        await activity.update(content)
    }

    func end(distanceCovered: Double, elapsedSeconds: Int) async {
        guard let activity else { return }
        let finalState = WalkActivityAttributes.ContentState(
            distanceCoveredMeters: distanceCovered,
            elapsedSeconds: elapsedSeconds,
            isPaused: false,
            paceSecsPerKm: nil
        )
        let content = ActivityContent(state: finalState, staleDate: .now)
        await activity.end(content, dismissalPolicy: .after(.now.addingTimeInterval(10)))
        self.activity = nil
    }
}
