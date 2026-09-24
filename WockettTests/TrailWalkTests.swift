import Testing
import CoreLocation
import MapKit
import Foundation
@testable import PoCSquat

/// Walking a trail: the plan a session gets (`TrailWalkPlanner`), and the
/// trail line surviving a crash-and-resume (`ActiveWalkSnapshot`).
@MainActor
struct TrailWalkTests {

    // MARK: Helpers

    /// Google's polyline encoding at precision 5 — what the pack builder
    /// writes. Checked below by round-tripping through the app's decoder.
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

    private func trail(_ coords: [CLLocationCoordinate2D], loop: Bool, name: String = "Test Trail") -> TrailFeature {
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        return TrailFeature(id: 1, sourceID: "osm", sourceRef: "w1", name: name,
                            encodedPolyline: encode(coords), pointCount: coords.count,
                            lengthMeters: TrailWalkPlanner.length(coords),
                            bounds: TrailBounds(minLatitude: lats.min() ?? 0, minLongitude: lons.min() ?? 0,
                                                maxLatitude: lats.max() ?? 0, maxLongitude: lons.max() ?? 0),
                            surface: nil, difficulty: nil, dogAccess: .unknown, dogAccessProvenance: .default,
                            allowsFoot: true, allowsBike: false, allowsHorse: false, isLoop: loop)
    }

    /// A straight line east from (35.78, -78.64): `count` points ~100 m apart.
    private func line(_ count: Int) -> [CLLocationCoordinate2D] {
        (0..<count).map { CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64 + Double($0) * 0.0011) }
    }

    /// A closed square ~400 m a side, first point repeated at the end as OSM does.
    private var square: [CLLocationCoordinate2D] {
        let a = CLLocationCoordinate2D(latitude: 35.780, longitude: -78.640)
        let b = CLLocationCoordinate2D(latitude: 35.780, longitude: -78.6356)
        let c = CLLocationCoordinate2D(latitude: 35.7836, longitude: -78.6356)
        let d = CLLocationCoordinate2D(latitude: 35.7836, longitude: -78.640)
        return [a, b, c, d, a]
    }

    @Test("The test encoder round-trips through the app's decoder")
    func encoderRoundTrip() {
        let decoded = EncodedPolyline.decode(encode(square))
        #expect(decoded.count == square.count)
        for (x, y) in zip(decoded, square) {
            #expect(abs(x.latitude - y.latitude) < 1e-5 && abs(x.longitude - y.longitude) < 1e-5)
        }
    }

    // MARK: Being at the trail

    @Test("No plan unless the person is within 150 m of the trail")
    func onlyAtTheTrail() {
        let t = trail(line(11), loop: false)
        let near = CLLocationCoordinate2D(latitude: 35.7809, longitude: -78.6345)   // ~100 m north of the line
        let far = CLLocationCoordinate2D(latitude: 35.7830, longitude: -78.6345)    // ~330 m north
        #expect(TrailWalkPlanner.plan(for: t, name: "x", from: near) != nil)
        #expect(TrailWalkPlanner.plan(for: t, name: "x", from: far) == nil)
    }

    @Test("For a grouped trail, the section you are at is the one walked")
    func sectionYouAreAt() {
        let west = trail(line(5), loop: false)
        let eastCoords = line(5).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude + 0.02) }
        var east = trail(eastCoords, loop: false)
        east = TrailFeature(id: 2, sourceID: east.sourceID, sourceRef: "w2", name: east.name,
                            encodedPolyline: east.encodedPolyline, pointCount: east.pointCount,
                            lengthMeters: east.lengthMeters, bounds: east.bounds, surface: nil, difficulty: nil,
                            dogAccess: .unknown, dogAccessProvenance: .default,
                            allowsFoot: true, allowsBike: false, allowsHorse: false, isLoop: false)
        let item = TrailListItem(id: "g1-2", name: "Test Trail", sections: [west, east], distanceMeters: 0)
        let atEast = eastCoords[2]
        #expect(TrailWalkPlanner.section(of: item, at: atEast)?.id == 2)
        #expect(TrailWalkPlanner.section(of: item, at: CLLocationCoordinate2D(latitude: 35.9, longitude: -78.6)) == nil)
        #expect(TrailWalkPlanner.section(of: item, at: nil) == nil)
    }

    // MARK: The path

    @Test("A line is walked from the nearest point toward its farther end")
    func lineGoesToFartherEnd() throws {
        let coords = line(11)                                  // ~1 km
        let t = trail(coords, loop: false)
        let nearThird = coords[3]
        let plan = try #require(TrailWalkPlanner.plan(for: t, name: "x", from: nearThird))
        #expect(plan.path.first?.longitude == coords[3].longitude)
        #expect(plan.path.last?.longitude == coords[10].longitude, "the east end is farther, so the walk heads east")
        #expect(!plan.isLoop)

        let nearEnd = coords[9]
        let back = try #require(TrailWalkPlanner.plan(for: t, name: "x", from: nearEnd))
        #expect(back.path.last?.longitude == coords[0].longitude, "near the east end, the walk heads west")
        #expect(abs(back.distanceMeters - TrailWalkPlanner.length(Array(coords[...9]))) < 1)
    }

    @Test("A loop starts where you are and closes back there")
    func loopStartsWhereYouAre() throws {
        let t = trail(square, loop: true)
        let atCorner = square[2]
        let plan = try #require(TrailWalkPlanner.plan(for: t, name: "x", from: atCorner))
        #expect(plan.isLoop)
        #expect(plan.path.first?.latitude == square[2].latitude && plan.path.first?.longitude == square[2].longitude)
        #expect(plan.path.last?.latitude == plan.path.first?.latitude && plan.path.last?.longitude == plan.path.first?.longitude)
        #expect(plan.path.count == 5, "four corners plus the return, with OSM's repeated end point dropped")
        #expect(abs(plan.distanceMeters - TrailWalkPlanner.length(square)) < 1)
    }

    // MARK: Checkpoints

    @Test("A loop always has at least two checkpoints past the start")
    func loopCheckpoints() throws {
        let plan = try #require(TrailWalkPlanner.plan(for: trail(square, loop: true), name: "x", from: square[0]))
        #expect(plan.waypoints.count >= 3,
                "with only the start, the session's first target would be the start and the lap would end at once")
        let startToFirst = TrailWalkPlanner.meters(plan.waypoints[0], plan.waypoints[1])
        #expect(startToFirst > 60, "the first checkpoint must lie outside the 60 m arrival radius")
    }

    @Test("A line ends on its last point, with checkpoints about 800 m apart")
    func lineCheckpoints() throws {
        let coords = line(41)                                  // ~4 km
        let plan = try #require(TrailWalkPlanner.plan(for: trail(coords, loop: false), name: "x", from: coords[0]))
        #expect(plan.waypoints.first?.longitude == coords[0].longitude)
        #expect(plan.waypoints.last?.longitude == coords[40].longitude)
        let gaps = zip(plan.waypoints, plan.waypoints.dropFirst()).map { TrailWalkPlanner.meters($0, $1) }
        #expect(gaps.dropLast().allSatisfy { abs($0 - 800) < 20 }, "gaps: \(gaps)")
    }

    // MARK: The session route

    @Test("The session route carries the trail's line, so no leg is routed on streets")
    func navigableRouteCarriesPath() throws {
        let plan = try #require(TrailWalkPlanner.plan(for: trail(square, loop: true), name: "Loop", from: square[0]))
        let route = plan.navigableRoute(activityMode: .running)
        #expect(route.path?.count == plan.path.count)
        #expect(route.isLoop && route.lapCount == 1)
        #expect(route.activityMode == .running)
        #expect(!route.isCustomRoute)
        let leg = RouteLeg(path: try #require(route.path))
        #expect(leg.polyline.pointCount == plan.path.count)
        #expect(abs(leg.distance - plan.distanceMeters) < 0.001)
    }

    @Test("A real bundled loop plans a full lap from any of its points")
    func realBundledLoop() throws {
        let url = try #require(Bundle.main.url(forResource: "nc", withExtension: "wktpack"))
        let source = try BundledTrailSource(url: url)
        let tulip = try #require(try source.trail(id: 8502))   // Tulip Poplar Trail, 1.1 mi, a loop
        #expect(tulip.isLoop)
        let vertex = tulip.coordinates[tulip.coordinates.count / 2]
        let plan = try #require(TrailWalkPlanner.plan(for: tulip, name: tulip.displayName, from: vertex))
        #expect(abs(plan.distanceMeters - tulip.lengthMeters) < tulip.lengthMeters * 0.01)
        #expect(plan.waypoints.count >= 3)
    }

    // MARK: Crash and resume

    @Test("A trail walk's line survives the crash snapshot")
    func snapshotKeepsPath() throws {
        let plan = try #require(TrailWalkPlanner.plan(for: trail(square, loop: true), name: "Loop", from: square[0]))
        let data = try JSONEncoder().encode(ActiveWalkSnapshot.RouteData(plan.navigableRoute(activityMode: .walking)))
        let restored = try JSONDecoder().decode(ActiveWalkSnapshot.RouteData.self, from: data).navigableRoute
        #expect(restored.path?.count == plan.path.count,
                "without it a resumed trail walk would be re-routed onto the streets")
    }

    @Test("A snapshot written before trail walks existed still restores, as a street route")
    func oldSnapshotStillDecodes() throws {
        let route = NavigableRoute(name: "Old", waypoints: square, lapCount: 1, isLoop: true, totalDistance: 1600)
        var json = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ActiveWalkSnapshot.RouteData(route))) as? [String: Any])
        json.removeValue(forKey: "path")
        let old = try JSONSerialization.data(withJSONObject: json)
        let restored = try JSONDecoder().decode(ActiveWalkSnapshot.RouteData.self, from: old).navigableRoute
        #expect(restored.path == nil)
        #expect(restored.waypoints.count == square.count)
    }
}
