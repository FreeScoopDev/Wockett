import Testing
import CoreLocation
import MapKit
import Foundation
@testable import PoCSquat

/// Getting to a trail from its detail (2026-09-26): which option leads, when
/// MapKit is asked again, the words and VoiceOver labels, and the session
/// that turns into the trail walk on arrival.
@MainActor
struct TrailDirectionsTests {

    // MARK: Which option leads

    @Test("On foot leads under 3 km, the bike from 3 km, Maps from 13 km")
    func leadThresholds() {
        typealias P = TrailDirectionsPlanner
        #expect(P.lead(distanceMeters: 800, activityMode: .walking) == .onFoot)
        #expect(P.lead(distanceMeters: 2_999, activityMode: .walking) == .onFoot)
        #expect(P.lead(distanceMeters: 3_000, activityMode: .walking) == .cycling)
        #expect(P.lead(distanceMeters: 12_999, activityMode: .walking) == .cycling)
        #expect(P.lead(distanceMeters: 13_000, activityMode: .walking) == .drive)
        #expect(P.lead(distanceMeters: 40_000, activityMode: .running) == .drive)
        #expect(P.lead(distanceMeters: 1_000, activityMode: .running) == .onFoot)
    }

    @Test("In Ride mode the bike leads until the trail is a drive away")
    func rideModeLeadsWithTheBike() {
        #expect(TrailDirectionsPlanner.lead(distanceMeters: 500, activityMode: .cycling) == .cycling)
        #expect(TrailDirectionsPlanner.lead(distanceMeters: 13_000, activityMode: .cycling) == .drive)
    }

    @Test("The leading option is listed first; driving keeps on foot first below it")
    func order() {
        #expect(TrailDirectionsPlanner.order(for: .onFoot) == [.onFoot, .cycling])
        #expect(TrailDirectionsPlanner.order(for: .cycling) == [.cycling, .onFoot])
        #expect(TrailDirectionsPlanner.order(for: .drive) == [.onFoot, .cycling])
    }

    @Test("On foot keeps a run a run; anything else on foot is a walk")
    func sessionModes() {
        #expect(TrailDirectionsMode.onFoot.sessionMode(current: .walking) == .walking)
        #expect(TrailDirectionsMode.onFoot.sessionMode(current: .running) == .running)
        #expect(TrailDirectionsMode.onFoot.sessionMode(current: .cycling) == .walking)
        #expect(TrailDirectionsMode.cycling.sessionMode(current: .walking) == .cycling)
        #expect(TrailDirectionsMode.cycling.transportType == .cycling)
        #expect(TrailDirectionsMode.onFoot.transportType == .walking)
    }

    // MARK: When to ask MapKit again

    private let raleigh = CLLocationCoordinate2D(latitude: 35.7796, longitude: -78.6382)

    @Test("MapKit is asked again only for another trail or after moving more than 100 m")
    func recomputeRule() {
        typealias P = TrailDirectionsPlanner
        let key = P.CacheKey(trailID: "a", origin: raleigh)
        let moved60 = raleigh.offset(bearing: 90, meters: 60)
        let moved140 = raleigh.offset(bearing: 90, meters: 140)
        #expect(P.needsRecompute(cached: nil, trailID: "a", origin: raleigh))
        #expect(!P.needsRecompute(cached: key, trailID: "a", origin: raleigh))
        #expect(!P.needsRecompute(cached: key, trailID: "a", origin: moved60))
        #expect(P.needsRecompute(cached: key, trailID: "a", origin: moved140))
        #expect(P.needsRecompute(cached: key, trailID: "b", origin: raleigh))
    }

    // MARK: Words

    @Test("Durations read as the app's others do, never 0 min")
    func durations() {
        #expect(TrailDirectionsPlanner.durationText(0) == "1 min")
        #expect(TrailDirectionsPlanner.durationText(18 * 60) == "18 min")
        #expect(TrailDirectionsPlanner.durationText(65 * 60) == "1h 5m")
        #expect(TrailDirectionsPlanner.spokenDuration(60) == "1 minute")
        #expect(TrailDirectionsPlanner.spokenDuration(18 * 60) == "18 minutes")
        #expect(TrailDirectionsPlanner.spokenDuration(60 * 60) == "1 hour")
        #expect(TrailDirectionsPlanner.spokenDuration(125 * 60) == "2 hours 5 minutes")
    }

    @Test("Each option is one VoiceOver sentence")
    func accessibilityLabel() {
        #expect(TrailDirectionsPlanner.accessibilityLabel(sessionLabel: "Walk", seconds: 18 * 60,
                                                          spokenDistance: "0.9 miles")
                == "Walk to trail, 18 minutes, 0.9 miles")
    }

    @Test("A run's time is estimated at an easy running pace, not MapKit's walking one")
    func runningTime() {
        #expect(abs(TrailDirectionsPlanner.travelSeconds(for: .running, expected: 1_900, meters: 2_700) - 1_000) < 0.001)
        #expect(TrailDirectionsPlanner.travelSeconds(for: .walking, expected: 1_900, meters: 2_700) == 1_900)
        #expect(TrailDirectionsPlanner.travelSeconds(for: .cycling, expected: 600, meters: 2_700) == 600)
    }

    @Test("Failures say what happened in plain words")
    func failureWords() {
        #expect(TrailDirectionsPlanner.failureMessage(for: MKError(.loadingThrottled)).contains("busy"))
        #expect(TrailDirectionsPlanner.failureMessage(for: URLError(.notConnectedToInternet)).contains("offline"))
        #expect(TrailDirectionsPlanner.failureMessage(for: nil).contains("Maps can still"))
    }

    // MARK: Arriving at the trail

    /// Google's polyline encoding at precision 5, as in TrailWalkTests.
    private func encode(_ coords: [CLLocationCoordinate2D]) -> String {
        var out = ""
        var lastLat = 0, lastLon = 0
        for c in coords {
            let lat = Int((c.latitude * 1e5).rounded()), lon = Int((c.longitude * 1e5).rounded())
            for delta in [lat - lastLat, lon - lastLon] {
                var v = delta < 0 ? ~(delta << 1) : (delta << 1)
                while v >= 0x20 {
                    out.append(Character(UnicodeScalar(UInt8((0x20 | (v & 0x1f)) + 63))))
                    v >>= 5
                }
                out.append(Character(UnicodeScalar(UInt8(v + 63))))
            }
            lastLat = lat; lastLon = lon
        }
        return out
    }

    /// A trail running ~1 km east from (35.78, -78.64).
    private var trailItem: TrailListItem {
        let coords = (0..<11).map { CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64 + Double($0) * 0.0011) }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let feature = TrailFeature(id: 1, sourceID: "osm", sourceRef: "w1", name: "Test Greenway",
                                   encodedPolyline: encode(coords), pointCount: coords.count,
                                   lengthMeters: TrailWalkPlanner.length(coords),
                                   bounds: TrailBounds(minLatitude: lats.min() ?? 0, minLongitude: lons.min() ?? 0,
                                                       maxLatitude: lats.max() ?? 0, maxLongitude: lons.max() ?? 0),
                                   surface: nil, difficulty: nil, dogAccess: .unknown, dogAccessProvenance: .default,
                                   allowsFoot: true, allowsBike: true, allowsHorse: false, isLoop: false)
        return TrailListItem(id: "osm:w1", name: "Test Greenway", sections: [feature], distanceMeters: 900)
    }

    private let home = CLLocationCoordinate2D(latitude: 35.7881, longitude: -78.6345)      // ~900 m north
    private let access = CLLocationCoordinate2D(latitude: 35.78, longitude: -78.6345)
    private let atTrail = CLLocationCoordinate2D(latitude: 35.7809, longitude: -78.6345)   // ~100 m north

    private func fix(_ c: CLLocationCoordinate2D) -> CLLocation {
        CLLocation(coordinate: c, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
    }

    @Test("The trail walk is offered within 150 m of the trail, and not before")
    func arrivalPlan() {
        let approach = TrailApproach(item: trailItem)
        #expect(approach.arrivalPlan(at: home) == nil)
        let plan = approach.arrivalPlan(at: atTrail)
        #expect(plan?.name == "Test Greenway")
        #expect((plan?.path.count ?? 0) >= 2)
    }

    @Test("A session heading to a trail offers the trail walk on arrival and never finishes at the access point")
    func sessionArrivesAndSwitches() throws {
        let approach = TrailApproach(item: trailItem)
        let route = approach.navigableRoute(from: home, to: access, distanceMeters: 1_100, activityMode: .walking)
        let mgr = NavigationSessionManager(route: route)
        #expect(mgr.trailProgress == nil, "the way there is a street route, not a line to follow")

        mgr.checkArrival(at: fix(home))
        #expect(!mgr.arrivedAtTrail)

        mgr.checkArrival(at: fix(access))
        #expect(mgr.arrivedAtTrail)
        #expect(!mgr.isCompleted, "reaching the access point must offer the trail, not end the session")

        mgr.totalDistanceCovered = 1_050
        let next = try #require(mgr.beginTrailWalk())
        #expect(next.name == "Test Greenway")
        #expect(next.path != nil)
        #expect(next.approach == nil)
        #expect(next.activityMode == .walking)
        #expect(mgr.route.id == next.id)
        #expect(mgr.trailProgress != nil)
        #expect(mgr.currentWaypointIndex == 1)
        #expect(mgr.legStartDistance == 1_050)
        #expect(!mgr.arrivedAtTrail)
        #expect(mgr.totalDistanceCovered == 1_050, "one session: the way there still counts")
        #expect(abs(mgr.remainingDistance - next.totalDistance) < 1,
                "before the first fix on the trail, all of it is left, not the trail less the way there")
    }

    @Test("A session not heading to a trail cannot be switched")
    func noApproachNoSwitch() {
        let mgr = NavigationSessionManager(route: NavigableRoute(name: "Park", waypoints: [home, access],
                                                                 lapCount: 1, isLoop: false, totalDistance: 900))
        #expect(mgr.beginTrailWalk() == nil)
    }

    @Test("The trail survives the crash snapshot, and old snapshots still decode")
    func snapshotKeepsApproach() throws {
        let approach = TrailApproach(item: trailItem)
        let route = approach.navigableRoute(from: home, to: access, distanceMeters: 1_100, activityMode: .cycling)
        let data = try JSONEncoder().encode(ActiveWalkSnapshot.RouteData(route))
        let restored = try JSONDecoder().decode(ActiveWalkSnapshot.RouteData.self, from: data).navigableRoute
        #expect(restored.approach?.trailName == "Test Greenway")
        #expect(restored.approach?.arrivalPlan(at: atTrail) != nil)
        #expect(restored.activityMode == .cycling)

        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "approach")
        let old = try JSONDecoder().decode(ActiveWalkSnapshot.RouteData.self,
                                           from: JSONSerialization.data(withJSONObject: json)).navigableRoute
        #expect(old.approach == nil)
    }
}
