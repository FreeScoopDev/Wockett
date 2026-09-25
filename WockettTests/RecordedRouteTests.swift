import Testing
import CoreLocation
import Foundation
@testable import PoCSquat

/// A recorded walk saved as a route is followed as its own line
/// (`RecordedRoute`), not routed leg by leg through MKDirections.
@MainActor
struct RecordedRouteTests {

    private final class Marker {}

    /// A real recording: the 1.0 mi walk replayed around Columbus Circle on
    /// 2026-09-24 and saved with "Save as Custom Route" — 311 points, the
    /// `waypointsData` of the CustomRouteRecord it produced. Opened in My
    /// Routes it sent 310 MKDirections requests; Apple refused 260.
    private func recording() throws -> [CLLocationCoordinate2D] {
        let url = try #require(Bundle(for: Marker.self).url(forResource: "recorded-walk", withExtension: "json"))
        return try JSONDecoder().decode([WaypointCoord].self, from: Data(contentsOf: url)).map(\.clCoordinate)
    }

    /// A route tapped out in the builder: `count` points ~150 m apart.
    private func handBuilt(_ count: Int) -> [CLLocationCoordinate2D] {
        (0..<count).map { CLLocationCoordinate2D(latitude: 40.768 + Double($0) * 0.00135, longitude: -73.982) }
    }

    /// A straight line north: `count` points `spacing` metres apart.
    private func line(spacing: Double, count: Int) -> [CLLocationCoordinate2D] {
        (0..<count).map { CLLocationCoordinate2D(latitude: 40.768 + Double($0) * spacing / 111_000, longitude: -73.982) }
    }

    private func navigable(_ points: [CLLocationCoordinate2D], isLoop: Bool = false) -> NavigableRoute {
        NavigableRoute(name: "Test", waypoints: points, lapCount: 1, isLoop: isLoop,
                       totalDistance: TrailWalkPlanner.length(points), isCustomRoute: true)
    }

    @Test("A real recording is followed as its line, with a few checkpoints")
    func recordingBecomesLine() throws {
        let points = try recording()
        #expect(points.count == 311)
        let line = try #require(RecordedRoute.line(for: points, isLoop: false))
        #expect(line.path.count == points.count)
        #expect(line.checkpoints.count >= 2 && line.checkpoints.count <= 5)
        #expect(TrailWalkPlanner.meters(line.checkpoints[0], points[0]) < 1)
        #expect(TrailWalkPlanner.meters(try #require(line.checkpoints.last), points[points.count - 1]) < 1)
    }

    @Test("Hand-built and generated routes are still routed leg by leg")
    func handBuiltRoutesUnchanged() {
        for count in [2, 4, 9, 12, 40] {
            #expect(!RecordedRoute.isRecorded(handBuilt(count)), "count \(count)")
        }
        let route = navigable(handBuilt(12))
        let same = route.followingRecordedLine()
        #expect(same.path == nil)
        #expect(same.waypoints.count == 12)
    }

    @Test("A recording too short to matter is left alone")
    func shortRecordingLeftAlone() throws {
        // Literal counts, not `minimumPoints`: the test must not take its
        // expectation from the value it checks.
        let points = try recording()
        #expect(!RecordedRoute.isRecorded(Array(points.prefix(9))))
        #expect(RecordedRoute.isRecorded(Array(points.prefix(10))))
    }

    @Test("The spacing rule: 12 m apart is a recording, 18 m is not")
    func spacingBoundary() {
        #expect(RecordedRoute.isRecorded(line(spacing: 12, count: 20)))
        #expect(!RecordedRoute.isRecorded(line(spacing: 18, count: 20)))
    }

    @Test("History keeps a recorded route's whole line, and a trail's checkpoints")
    func historyKeepsRecordedLine() throws {
        let points = try recording()
        let recorded = NavigationSessionManager(route: navigable(points).followingRecordedLine())
        let saved = recorded.completedSession.waypoints.map(\.clCoordinate)
        #expect(saved.count == points.count)
        #expect(RecordedRoute.isRecorded(saved))   // restarted from Past Walks, it is followed again

        var trail = navigable(Array(points.prefix(3)))
        trail.path = points                         // a trail's line: not a recording
        #expect(NavigationSessionManager(route: trail).completedSession.waypoints.count == 3)
    }

    @Test("Off-line guidance calls a recording a route and a trail a trail, and measures along it")
    func guidanceOnRecordedLine() throws {
        let route = navigable(try recording()).followingRecordedLine()
        #expect(route.lineNoun == "route")
        var trail = route
        trail.pathIsRecording = false
        #expect(trail.lineNoun == "trail")
        #expect(TrailProgress(route: route) != nil)   // #65's along-the-line progress applies
    }

    @Test("A crash snapshot keeps the recording flag; older snapshots read as a trail")
    func snapshotKeepsFlag() throws {
        let route = navigable(try recording()).followingRecordedLine()
        let data = try JSONEncoder().encode(ActiveWalkSnapshot.RouteData(route))
        #expect(try JSONDecoder().decode(ActiveWalkSnapshot.RouteData.self, from: data).navigableRoute.pathIsRecording)

        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "pathIsRecording")
        let old = try JSONSerialization.data(withJSONObject: json)
        #expect(!(try JSONDecoder().decode(ActiveWalkSnapshot.RouteData.self, from: old).navigableRoute.pathIsRecording))
    }

    @Test("A recorded loop closes its line and keeps two checkpoints past the start")
    func recordedLoop() throws {
        let points = Array(try recording().dropLast(20))   // ends short of the start
        let line = try #require(RecordedRoute.line(for: points, isLoop: true))
        #expect(TrailWalkPlanner.meters(try #require(line.path.last), points[0]) < 1)
        #expect(line.checkpoints.count >= 3)
    }

    @Test("Starting a recorded route gives the session a line, not 310 legs")
    func beginSessionFollowsLine() throws {
        let store = ActiveWalkStore.shared
        try #require(store.session == nil)
        defer { store.endSession() }

        let points = try recording()
        try #require(store.beginSession(route: navigable(points)) != nil)
        let active = try #require(store.activeRoute)
        #expect(active.path?.count == points.count)
        #expect(active.pathIsRecording)
        #expect(active.waypoints.count <= 5)
        #expect(active.isCustomRoute)
    }

    @Test("Starting a hand-built route leaves it for MKDirections")
    func beginSessionLeavesHandBuilt() throws {
        let store = ActiveWalkStore.shared
        try #require(store.session == nil)
        defer { store.endSession() }

        try #require(store.beginSession(route: navigable(handBuilt(6))) != nil)
        let active = try #require(store.activeRoute)
        #expect(active.path == nil)
        #expect(active.waypoints.count == 6)
    }
}
