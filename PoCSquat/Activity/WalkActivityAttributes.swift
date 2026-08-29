import ActivityKit
import Foundation

// MARK: - WalkActivityAttributes
//
// Shared between the main app (starts/updates the activity) and the widget
// extension (renders it). This file MUST be added to both targets:
//   File Inspector (⌘⌥1) → Target Membership → check PoCSquat

public struct WalkActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var distanceCoveredMeters: Double
        public var elapsedSeconds: Int
        public var isPaused: Bool
        public var paceSecsPerKm: Double?
        public var pausedDuration: Double   // cumulative seconds paused so far, as of this push
        public var pauseTime: Date?         // wall-clock moment this paused state was captured; nil while running

        public init(distanceCoveredMeters: Double, elapsedSeconds: Int,
                    isPaused: Bool, paceSecsPerKm: Double?,
                    pausedDuration: Double, pauseTime: Date?) {
            self.distanceCoveredMeters = distanceCoveredMeters
            self.elapsedSeconds        = elapsedSeconds
            self.isPaused              = isPaused
            self.paceSecsPerKm         = paceSecsPerKm
            self.pausedDuration        = pausedDuration
            self.pauseTime             = pauseTime
        }
    }

    public let routeName: String
    public let totalDistanceMeters: Double
    public let activityMode: String   // "walking", "cycling", "stationary"
    public let startDate: Date        // fixed reference point for the live-ticking timer

    public init(routeName: String, totalDistanceMeters: Double, activityMode: String, startDate: Date) {
        self.routeName            = routeName
        self.totalDistanceMeters  = totalDistanceMeters
        self.activityMode         = activityMode
        self.startDate            = startDate
    }
}
