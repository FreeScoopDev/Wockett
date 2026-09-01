import Foundation
import CoreLocation

// MARK: - Pending guided walk (saved across force-quits for resume)

struct PendingGuidedWalk: Codable, Identifiable {
    var id: Date { savedAt }
    let routeName: String
    let waypoints: [WaypointCoord]
    let lapCount: Int
    let isLoop: Bool
    let totalDistance: Double
    let isCustomRoute: Bool
    let activityMode: String
    let currentWaypointIndex: Int
    let totalDistanceCovered: Double
    let elapsedTime: TimeInterval
    let petDistances: [String: Double]
    let activePetIds: [UUID]
    let savedAt: Date

    func toNavigableRoute() -> NavigableRoute {
        NavigableRoute(
            name: routeName,
            waypoints: waypoints.map { $0.clCoordinate },
            lapCount: lapCount,
            isLoop: isLoop,
            totalDistance: totalDistance,
            isCustomRoute: isCustomRoute,
            activityMode: ActivityMode(rawValue: activityMode) ?? .walking
        )
    }
}

// MARK: - Pending free walk

struct PendingFreeWalk: Codable, Identifiable {
    var id: Date { savedAt }
    let trackPoints: [WaypointCoord]
    let totalDistance: Double
    let elapsedSeconds: Int
    let activityMode: String
    let savedAt: Date
}

// MARK: - Walk Persistence Store

@Observable
final class WalkPersistenceStore {
    static let shared = WalkPersistenceStore()

    var pendingGuidedWalk: PendingGuidedWalk?
    var pendingFreeWalk: PendingFreeWalk?

    private let guidedKey = "wkt_pendingGuided_v1"
    private let freeKey   = "wkt_pendingFree_v1"
    private let expiry: TimeInterval = 4 * 3600

    private init() { load() }

    func saveGuided(route: NavigableRoute, waypointIndex: Int, distanceCovered: Double,
                    elapsedTime: TimeInterval, petDistances: [String: Double], activePetIds: [UUID]) {
        let pending = PendingGuidedWalk(
            routeName: route.name,
            waypoints: route.waypoints.map { WaypointCoord($0) },
            lapCount: route.lapCount, isLoop: route.isLoop,
            totalDistance: route.totalDistance, isCustomRoute: route.isCustomRoute,
            activityMode: route.activityMode.rawValue,
            currentWaypointIndex: waypointIndex,
            totalDistanceCovered: distanceCovered,
            elapsedTime: elapsedTime,
            petDistances: petDistances,
            activePetIds: activePetIds,
            savedAt: Date()
        )
        pendingGuidedWalk = pending
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: guidedKey)
        }
    }

    func saveFree(trackPoints: [CLLocationCoordinate2D], totalDistance: Double,
                  elapsedSeconds: Int, activityMode: ActivityMode) {
        let pending = PendingFreeWalk(
            trackPoints: trackPoints.map { WaypointCoord($0) },
            totalDistance: totalDistance,
            elapsedSeconds: elapsedSeconds,
            activityMode: activityMode.rawValue,
            savedAt: Date()
        )
        pendingFreeWalk = pending
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: freeKey)
        }
    }

    func clearGuided() {
        pendingGuidedWalk = nil
        UserDefaults.standard.removeObject(forKey: guidedKey)
    }

    func clearFree() {
        pendingFreeWalk = nil
        UserDefaults.standard.removeObject(forKey: freeKey)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: guidedKey),
           let w = try? JSONDecoder().decode(PendingGuidedWalk.self, from: data),
           Date().timeIntervalSince(w.savedAt) < expiry {
            pendingGuidedWalk = w
        } else {
            UserDefaults.standard.removeObject(forKey: guidedKey)
        }
        if let data = UserDefaults.standard.data(forKey: freeKey),
           let w = try? JSONDecoder().decode(PendingFreeWalk.self, from: data),
           Date().timeIntervalSince(w.savedAt) < expiry {
            pendingFreeWalk = w
        } else {
            UserDefaults.standard.removeObject(forKey: freeKey)
        }
    }
}
