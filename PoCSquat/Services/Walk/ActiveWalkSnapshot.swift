import Foundation
import CoreLocation
import OSLog

// MARK: - Active Walk Snapshot
//
// A lightweight, periodically-written checkpoint of an in-progress walk,
// so it can be reconstructed if the app process dies unexpectedly
// (force-quit, memory pressure, crash) before the user ends the walk
// normally. See ActiveWalkSnapshotStore for read/write/clear, and
// NavigationSessionManager.restore(from:) for reconstruction.

nonisolated struct ActiveWalkSnapshot: Codable {
    struct RouteData: Codable {
        let name: String
        let waypoints: [WaypointCoord]
        let lapCount: Int
        let isLoop: Bool
        let totalDistance: Double
        let isCustomRoute: Bool
        let isCommunityRoute: Bool
        let activityMode: String
        let customRouteId: UUID?

        init(_ route: NavigableRoute) {
            name = route.name
            waypoints = route.waypoints.map { WaypointCoord($0) }
            lapCount = route.lapCount
            isLoop = route.isLoop
            totalDistance = route.totalDistance
            isCustomRoute = route.isCustomRoute
            isCommunityRoute = route.isCommunityRoute
            activityMode = route.activityMode.rawValue
            customRouteId = route.customRouteId
        }

        var navigableRoute: NavigableRoute {
            NavigableRoute(
                name: name,
                waypoints: waypoints.map { $0.clCoordinate },
                lapCount: lapCount,
                isLoop: isLoop,
                totalDistance: totalDistance,
                isCustomRoute: isCustomRoute,
                isCommunityRoute: isCommunityRoute,
                activityMode: ActivityMode(rawValue: activityMode) ?? .walking,
                customRouteId: customRouteId
            )
        }
    }

    struct SplitTimeRecord: Codable {
        let label: String
        let elapsed: TimeInterval
    }

    let route: RouteData
    let startTime: Date
    let totalDistanceCovered: Double
    let pausedDuration: TimeInterval   // completed pauses only, not one in progress
    let isPaused: Bool
    let pauseStartDate: Date?          // set only if isPaused was true at checkpoint time
    let currentWaypointIndex: Int
    let currentLap: Int
    let triggeredCheckpoints: Set<Int>
    let splitTimes: [SplitTimeRecord]
    let liveSteps: Int
    let checkpointDate: Date           // when this snapshot was written
    let trackPoints: [WaypointCoord]?  // GPS breadcrumbs; optional so pre-existing checkpoint files still decode

    init(route: RouteData, startTime: Date, totalDistanceCovered: Double,
         pausedDuration: TimeInterval, isPaused: Bool, pauseStartDate: Date?,
         currentWaypointIndex: Int, currentLap: Int, triggeredCheckpoints: Set<Int>,
         splitTimes: [SplitTimeRecord], liveSteps: Int, checkpointDate: Date,
         trackPoints: [WaypointCoord]? = nil) {
        self.route = route; self.startTime = startTime
        self.totalDistanceCovered = totalDistanceCovered
        self.pausedDuration = pausedDuration; self.isPaused = isPaused
        self.pauseStartDate = pauseStartDate
        self.currentWaypointIndex = currentWaypointIndex; self.currentLap = currentLap
        self.triggeredCheckpoints = triggeredCheckpoints; self.splitTimes = splitTimes
        self.liveSteps = liveSteps; self.checkpointDate = checkpointDate
        self.trackPoints = trackPoints
    }
}

// MARK: - Active Walk Snapshot Store

enum ActiveWalkSnapshotStore {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Wockett", category: "ActiveWalkSnapshot")
    /// Checkpoints older than this are considered stale and are deleted on
    /// read instead of offered for resume. Matches the privacy policy's
    /// "saved for up to 4 hours, then automatically deleted."
    static let maxSnapshotAge: TimeInterval = 4 * 60 * 60

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("active-walk-snapshot.json")
    }

    static func save(_ snapshot: ActiveWalkSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        // File protection: .completeUntilFirstUserAuthentication (default) — required because
        // checkpoints are written in the background mid-walk.
        var url = fileURL
        do {
            try data.write(to: url, options: .atomic)
            // This file holds GPS breadcrumbs and must never leave the device.
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? url.setResourceValues(resourceValues)
        } catch {
            log.error("Snapshot write failed")
        }
    }

    /// Returns the checkpoint only if it's fresh enough to offer for resume.
    /// A stale file is left in place — ActiveWalkStore decides its fate
    /// (salvage to history); nothing here silently deletes a user's walk.
    static func load() -> ActiveWalkSnapshot? {
        guard let snapshot = loadAnyAge(),
              Date().timeIntervalSince(snapshot.checkpointDate) <= maxSnapshotAge
        else { return nil }
        return snapshot
    }

    /// Raw read with no age check — for the salvage path.
    static func loadAnyAge() -> ActiveWalkSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ActiveWalkSnapshot.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    static var hasPending: Bool {
        load() != nil
    }

    /// Elapsed time a salvaged walk should record: the walk effectively
    /// ended at the last checkpoint (or at pause start, if it died while
    /// paused) — dead time after that never counts.
    static func salvagedElapsed(for snapshot: ActiveWalkSnapshot) -> TimeInterval {
        let endDate = snapshot.isPaused
            ? (snapshot.pauseStartDate ?? snapshot.checkpointDate)
            : snapshot.checkpointDate
        return max(0, endDate.timeIntervalSince(snapshot.startTime) - snapshot.pausedDuration)
    }
}
