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

        public init(distanceCoveredMeters: Double, elapsedSeconds: Int,
                    isPaused: Bool, paceSecsPerKm: Double?) {
            self.distanceCoveredMeters = distanceCoveredMeters
            self.elapsedSeconds        = elapsedSeconds
            self.isPaused              = isPaused
            self.paceSecsPerKm         = paceSecsPerKm
        }
    }

    public let routeName: String
    public let totalDistanceMeters: Double
    public let activityMode: String   // "walking", "cycling", "stationary"

    public init(routeName: String, totalDistanceMeters: Double, activityMode: String) {
        self.routeName            = routeName
        self.totalDistanceMeters  = totalDistanceMeters
        self.activityMode         = activityMode
    }
}
