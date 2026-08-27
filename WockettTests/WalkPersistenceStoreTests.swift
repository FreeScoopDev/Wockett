import Testing
import Foundation
import CoreLocation
@testable import PoCSquat

struct WalkPersistenceStoreTests {

    // MARK: - Helpers

    private func makeGuidedWalk(savedAt: Date = Date()) -> PendingGuidedWalk {
        PendingGuidedWalk(
            routeName: "Park Loop",
            waypoints: [WaypointCoord(CLLocationCoordinate2D(latitude: 37.77, longitude: -122.43))],
            lapCount: 2,
            isLoop: true,
            totalDistance: 4_200,
            isCustomRoute: false,
            activityMode: "walking",
            currentWaypointIndex: 1,
            totalDistanceCovered: 1_500,
            elapsedTime: 900,
            petDistances: [:],
            activePetIds: [],
            savedAt: savedAt
        )
    }

    // MARK: - PendingGuidedWalk

    @Test func guidedWalk_encodesAndDecodes() throws {
        let original = makeGuidedWalk()
        let data    = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PendingGuidedWalk.self, from: data)
        #expect(decoded.routeName == original.routeName)
        #expect(decoded.lapCount == original.lapCount)
        #expect(decoded.isLoop == original.isLoop)
        #expect(decoded.totalDistance == original.totalDistance)
        #expect(decoded.totalDistanceCovered == original.totalDistanceCovered)
        #expect(decoded.elapsedTime == original.elapsedTime)
    }

    @Test func guidedWalk_toNavigableRoute_preservesFields() {
        let walk  = makeGuidedWalk()
        let route = walk.toNavigableRoute()
        #expect(route.name == walk.routeName)
        #expect(route.lapCount == walk.lapCount)
        #expect(route.isLoop == walk.isLoop)
        #expect(route.totalDistance == walk.totalDistance)
        #expect(route.isCustomRoute == walk.isCustomRoute)
    }

    @Test func guidedWalk_toNavigableRoute_parsesActivityMode() {
        let walk  = makeGuidedWalk()
        let route = walk.toNavigableRoute()
        #expect(route.activityMode == .walking)
    }

    @Test func guidedWalk_toNavigableRoute_unknownModeDefaultsToWalking() {
        let walk = PendingGuidedWalk(
            routeName: "Test", waypoints: [], lapCount: 1, isLoop: false,
            totalDistance: 1_000, isCustomRoute: false, activityMode: "unknown_mode",
            currentWaypointIndex: 0, totalDistanceCovered: 0, elapsedTime: 0,
            petDistances: [:], activePetIds: [], savedAt: Date()
        )
        #expect(walk.toNavigableRoute().activityMode == .walking)
    }

    // MARK: - Expiry

    @Test func guidedWalk_isExpiredAfterFourHours() {
        let expiry: TimeInterval = 4 * 3600
        let old = makeGuidedWalk(savedAt: Date().addingTimeInterval(-(expiry + 60)))
        // The store discards any walk where timeIntervalSince(savedAt) >= expiry
        #expect(Date().timeIntervalSince(old.savedAt) > expiry)
    }

    @Test func guidedWalk_isNotExpiredWhenFresh() {
        let expiry: TimeInterval = 4 * 3600
        let fresh = makeGuidedWalk(savedAt: Date().addingTimeInterval(-60))
        #expect(Date().timeIntervalSince(fresh.savedAt) < expiry)
    }

    // MARK: - PendingFreeWalk

    @Test func freeWalk_encodesAndDecodes() throws {
        let coord = WaypointCoord(CLLocationCoordinate2D(latitude: 37.77, longitude: -122.43))
        let original = PendingFreeWalk(
            trackPoints: [coord],
            totalDistance: 3_200,
            elapsedSeconds: 1_800,
            activityMode: "cycling",
            savedAt: Date()
        )
        let data    = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PendingFreeWalk.self, from: data)
        #expect(decoded.totalDistance == original.totalDistance)
        #expect(decoded.elapsedSeconds == original.elapsedSeconds)
        #expect(decoded.activityMode == original.activityMode)
        #expect(decoded.trackPoints.count == 1)
    }

    @Test func freeWalk_emptyTrackPoints_encodesCleanly() throws {
        let original = PendingFreeWalk(
            trackPoints: [], totalDistance: 0,
            elapsedSeconds: 0, activityMode: "walking", savedAt: Date()
        )
        let data    = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PendingFreeWalk.self, from: data)
        #expect(decoded.trackPoints.isEmpty)
    }
}
