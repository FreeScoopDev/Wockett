import Testing
import CloudKit
import CoreLocation
import MapKit
@testable import PoCSquat

/// A shared route goes public without at least its first and last 200 m,
/// measured along the path, and only as original waypoints, so the start can't
/// be measured or drawn back from what is published. Distances are on a
/// meridian, where a thousandth of a degree of latitude is about 111 m.
@MainActor
struct SharedRouteTrimTests {

    private let home = CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64)

    /// `count` points north from home, `step` degrees apart.
    private func line(_ count: Int, step: Double = 0.001) -> [WaypointCoord] {
        (0..<count).map { WaypointCoord(CLLocationCoordinate2D(latitude: home.latitude + Double($0) * step,
                                                               longitude: home.longitude)) }
    }

    /// A point `east` and `north` metres from home.
    private func offset(east: Double, north: Double) -> WaypointCoord {
        WaypointCoord(CLLocationCoordinate2D(
            latitude: home.latitude + north / 111_000,
            longitude: home.longitude + east / (111_000 * cos(home.latitude * .pi / 180))))
    }

    /// Planar metres east and north of home.
    private func local(_ p: WaypointCoord) -> (x: Double, y: Double) {
        ((p.longitude - home.longitude) * 111_000 * cos(home.latitude * .pi / 180),
         (p.latitude - home.latitude) * 111_000)
    }

    /// How far home lies from the infinite line through `a` and `b`.
    private func homeOffLine(_ a: WaypointCoord, _ b: WaypointCoord) -> Double {
        let p = local(a), q = local(b)
        let dx = q.x - p.x, dy = q.y - p.y
        return abs(dx * p.y - dy * p.x) / (dx * dx + dy * dy).squareRoot()
    }

    private func metres(_ a: WaypointCoord, _ b: WaypointCoord) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private func trimmed(_ waypoints: [WaypointCoord], isLoop: Bool = false,
                         extra: (start: Double, end: Double) = (0, 0)) throws -> SharedRouteTrim.Trimmed {
        guard case .trimmed(let t) = SharedRouteTrim.trim(waypoints, isLoop: isLoop, extra: extra) else {
            Issue.record("expected a trimmed route"); throw CancellationError()
        }
        return t
    }

    @Test("Only original waypoints at least 200 m from each end are published")
    func snapsToWaypointsPastTheCut() throws {
        let path = line(11)                      // about 1,109 m, a point every 111 m
        let t = try trimmed(path)
        #expect(t.waypoints == Array(path[2...8]))
        #expect(abs(t.fullMeters - 1109.5) < 1)
        #expect(abs(t.keptMeters - 665.7) < 1)
    }

    @Test("The per-route extra comes off on top of the 200 m")
    func extraTrim() throws {
        let t = try trimmed(line(11), extra: (50, 80))
        #expect(t.waypoints == Array(line(11)[3...7]))
    }

    @Test("A route's extra trim is fixed by its id and stays within 0-100 m")
    func extraFromID() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000FF"))
        let e = SharedRouteTrim.extraTrim(for: id)
        #expect(e.start == 0)
        #expect(e.end == 100)
        let other = SharedRouteTrim.extraTrim(for: UUID())
        #expect((0...100).contains(other.start) && (0...100).contains(other.end))
    }

    @Test("No published point lies within 200 m of either end")
    func nothingNearTheEnds() throws {
        let path = line(30, step: 0.0002)        // dense, like a recorded walk
        let t = try trimmed(path)
        for point in t.waypoints {
            #expect(metres(path[0], point) >= 200)
            #expect(metres(path[path.count - 1], point) >= 200)
        }
    }

    @Test("A planned loop from home can't be drawn back to home from what is published")
    func plannedLoopHidesHome() throws {
        // RouteManager's shape: home, then three corners 400 m apart; the leg home is implicit.
        let a = offset(east: 0, north: 400), b = offset(east: 400, north: 400), c = offset(east: 400, north: 0)
        let t = try trimmed([offset(east: 0, north: 0), a, b, c], isLoop: true)
        #expect(t.waypoints == [a, b, c])
        // Extending the first or last published leg doesn't pass near home.
        #expect(homeOffLine(t.waypoints[0], t.waypoints[1]) > 150)
        let n = t.waypoints.count
        #expect(homeOffLine(t.waypoints[n - 2], t.waypoints[n - 1]) > 150)
    }

    @Test("A planned route of one straight leg can't be shared")
    func singleLegRefused() {
        let route = [offset(east: 0, north: 0), offset(east: 0, north: 1_200)]
        #expect(SharedRouteTrim.trim(route, isLoop: false) == .tooFewPoints)
    }

    @Test("A loop is closed first, so its end is trimmed back from the start too")
    func loopClosesBeforeTrimming() throws {
        let p = line(9)
        let t = try trimmed([p[0], p[2], p[5], p[8]], isLoop: true)
        #expect(abs(t.fullMeters - 1775.3) < 1)
        #expect(t.waypoints == [p[2], p[5], p[8]])
        let open = try trimmed([p[0], p[2], p[5], p[8]], isLoop: false)
        #expect(open.waypoints == [p[2], p[5]])
    }

    @Test("A loop that already returns to its start isn't closed twice")
    func closedLoopUnchanged() throws {
        let p = line(9)
        let t = try trimmed([p[0], p[2], p[5], p[8], p[0]], isLoop: true)
        #expect(abs(t.fullMeters - 1775.3) < 1)
    }

    @Test("Under 600 m is not shared; just over is")
    func shortRoutes() throws {
        guard case .tooShort(let full) = SharedRouteTrim.trim(line(2, step: 0.0053), isLoop: false) else {
            Issue.record("588 m should be too short"); return
        }
        #expect(abs(full - 588) < 1)
        let t = try trimmed(line(7))             // about 666 m
        #expect(t.waypoints == Array(line(7)[2...4]))
    }

    @Test("Empty, one point and all-duplicate routes are too short, not a crash")
    func degenerate() {
        let p = line(1)[0]
        #expect(SharedRouteTrim.trim([], isLoop: false) == .tooShort(fullMeters: 0))
        #expect(SharedRouteTrim.trim([p], isLoop: false) == .tooShort(fullMeters: 0))
        #expect(SharedRouteTrim.trim([p], isLoop: true) == .tooShort(fullMeters: 0))
        #expect(SharedRouteTrim.trim([p, p, p], isLoop: true) == .tooShort(fullMeters: 0))
    }

    @Test("Duplicate points change nothing: no NaN, no repeated point")
    func duplicates() throws {
        let path = line(11)
        let a = try trimmed(path), b = try trimmed(path.flatMap { [$0, $0] })
        #expect(b.waypoints == a.waypoints)
        #expect(abs(b.keptMeters - a.keptMeters) < 0.001)
    }

    @Test("The published distance is the kept share of the route's distance")
    func publishedDistance() {
        let t = SharedRouteTrim.Trimmed(waypoints: [], fullMeters: 1000, keptMeters: 600)
        #expect(t.publishedDistance(totalDistance: 2000) == 1200)
        #expect(t.publishedDistance(totalDistance: 0) == 600)
        #expect(t.publishedDistance(totalDistance: .nan) == 600)
    }

    @Test("The public record holds the trimmed path, its distance, and is never a loop")
    func publicRecord() throws {
        let path = line(11)
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))   // no extra trim
        let route = CustomRoute(id: id, name: "Lake loop", waypoints: path, totalDistance: 2_400,
                                isLoop: true, createdAt: Date())
        let record = try CommunityRouteService.record(for: route)
        let json = try #require(record["waypointsJSON"] as? String)
        let published = try JSONDecoder().decode([WaypointCoord].self, from: Data(json.utf8))
        let t = try trimmed(path, isLoop: true)
        // Through JSON and back: the same points to well under a millimetre.
        #expect(published.count == t.waypoints.count)
        for (a, b) in zip(published, t.waypoints) { #expect(metres(a, b) < 0.001) }
        #expect(published.allSatisfy { metres($0, path[0]) >= 200 })
        #expect(record["isLoop"] as? Int == 0)
        let distance = try #require(record["distanceMeters"] as? Double)
        #expect(abs(distance - 2_400 * t.keptMeters / t.fullMeters) < 0.001)
        #expect(distance < 2_400)
        #expect(route.waypoints == path, "the copy the user keeps is untouched")
    }

    @Test("Publishing a route that can't be trimmed throws before anything is written")
    func cannotShareThrows() {
        let route = CustomRoute(id: UUID(), name: "Block", waypoints: line(3), totalDistance: 222,
                                isLoop: false, createdAt: Date())
        #expect(throws: SharedRouteTrim.CannotShareError.self) { try CommunityRouteService.record(for: route) }
        let outcome = SharedRouteTrim.trim(route)
        #expect(!RouteSharePrivacyNote.canShare(outcome))
        #expect(RouteSharePrivacyNote.text(for: outcome, totalDistance: 222).hasPrefix("This route is too short to share."))
    }

    @Test("A suggested route shares one lap of its directions path, not its straight legs")
    func suggestedRouteSharesDirectionsPath() {
        var coords = line(5).map(\.clCoordinate)
        let polyline = MKPolyline(coordinates: &coords, count: coords.count)
        let suggested = SuggestedRoute(polyline: polyline,
                                       openInMapsItem: MKMapItem(location: CLLocation(latitude: home.latitude,
                                                                                      longitude: home.longitude),
                                                                 address: nil),
                                       isLoop: true, bearing: 0, totalDistance: 3_000, totalTime: 1_800,
                                       lapCount: 2, label: nil,
                                       legWaypoints: [home, line(5)[4].clCoordinate])
        let shared = suggested.shareableRoute(name: "Loop")
        // MKPolyline stores map points, so coordinates come back within a hair of what went in.
        #expect(shared.waypoints.count == 5)
        for (a, b) in zip(shared.waypoints, line(5)) { #expect(metres(a, b) < 0.01) }
        #expect(shared.totalDistance == 1_500)
        #expect(suggested.toCustomRoute().waypoints.count == 2, "the private copy keeps its legs")
    }
}
