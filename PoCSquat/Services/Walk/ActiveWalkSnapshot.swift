import Foundation
import CoreLocation

// MARK: - Active Walk Snapshot
//
// A lightweight, periodically-written checkpoint of an in-progress walk,
// so it can be reconstructed if the app process dies unexpectedly
// (force-quit, memory pressure, crash) before the user ends the walk
// normally. See ActiveWalkSnapshotStore for read/write/clear, and
// NavigationSessionManager.restore(from:) for reconstruction.

struct ActiveWalkSnapshot: Codable {
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
}

// MARK: - Active Walk Snapshot Store

enum ActiveWalkSnapshotStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("active-walk-snapshot.json")
    }

    static func save(_ snapshot: ActiveWalkSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func load() -> ActiveWalkSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ActiveWalkSnapshot.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    static var hasPending: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }
}
