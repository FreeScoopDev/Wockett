import Testing
import CoreLocation
@testable import PoCSquat

// NavigationSessionManager is @Observable @MainActor, so every test that touches it
// must run on the main actor.

struct NavigationSessionTests {

    // MARK: - Helpers (no @MainActor needed — pure value construction)

    private func freeWalkRoute() -> NavigableRoute {
        NavigableRoute(
            name: "Free Walk",
            waypoints: [],
            lapCount: 1,
            isLoop: false,
            totalDistance: 0
        )
    }

    private func guidedRoute(
        name: String = "Park Loop",
        waypoints: [CLLocationCoordinate2D],
        activityMode: ActivityMode = .walking
    ) -> NavigableRoute {
        NavigableRoute(
            name: name,
            waypoints: waypoints,
            lapCount: 1,
            isLoop: false,
            totalDistance: 2000,
            activityMode: activityMode
        )
    }

    // MARK: - Empty-waypoint route

    @Test @MainActor func emptyRoute_nextWaypointIsNil() {
        let mgr = NavigationSessionManager(route: freeWalkRoute())
        #expect(mgr.nextWaypoint == nil)
    }

    // MARK: - completedSession uses trackPoints for free walks

    @Test @MainActor func completedSession_usesTrackPointsForFreeWalk() {
        let mgr    = NavigationSessionManager(route: freeWalkRoute())
        let coordA = CLLocationCoordinate2D(latitude: 37.77, longitude: -122.43)
        let coordB = CLLocationCoordinate2D(latitude: 37.78, longitude: -122.44)
        mgr.trackPoints = [coordA, coordB]

        let session = mgr.completedSession
        #expect(session.waypoints.count == 2)
        #expect(abs(session.waypoints[0].latitude  - 37.77)   < 0.0001)
        #expect(abs(session.waypoints[0].longitude - (-122.43)) < 0.0001)
        #expect(abs(session.waypoints[1].latitude  - 37.78)   < 0.0001)
        #expect(abs(session.waypoints[1].longitude - (-122.44)) < 0.0001)
    }

    // MARK: - completedSession uses route waypoints for guided walks

    @Test @MainActor func completedSession_usesRouteWaypointsForGuidedWalk() {
        let routeCoords = [
            CLLocationCoordinate2D(latitude: 10.0, longitude: 20.0),
            CLLocationCoordinate2D(latitude: 11.0, longitude: 21.0)
        ]
        let mgr = NavigationSessionManager(route: guidedRoute(waypoints: routeCoords))
        // Inject breadcrumb coords that differ from the route waypoints.
        mgr.trackPoints = [CLLocationCoordinate2D(latitude: 99.0, longitude: 99.0)]

        let session = mgr.completedSession
        // Must use route waypoints, not trackPoints.
        #expect(session.waypoints.count == 2)
        #expect(abs(session.waypoints[0].latitude - 10.0) < 0.0001)
        #expect(abs(session.waypoints[1].latitude - 11.0) < 0.0001)
    }

    // MARK: - completedSession carries the route's activity mode

    @Test @MainActor func completedSession_activityTypeMatchesRoute() {
        let route = NavigableRoute(
            name: "Bike Loop",
            waypoints: [],
            lapCount: 1,
            isLoop: false,
            totalDistance: 0,
            activityMode: .cycling
        )
        let mgr = NavigationSessionManager(route: route)
        #expect(mgr.completedSession.activityType == ActivityMode.cycling.rawValue)
    }
}
