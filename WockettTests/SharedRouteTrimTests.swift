import Testing
import CloudKit
import CoreLocation
import MapKit
@testable import PoCSquat

/// A shared route goes public without anything within at least 200 m of its
/// start or finish, along the path or in a straight line, only as a path (never
/// the points a route was planned from), and respaced every 10 m. Each case
/// here is a way the start was recovered from an earlier version (critic,
/// 2026-10-13). Paths run from `home`; a ten-thousandth of a degree of latitude
/// is about 11.1 m.
@MainActor
struct SharedRouteTrimTests {

    private let home = CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64)

    /// `count` points north from home, `step` degrees apart.
    private func line(_ count: Int, step: Double = 0.0001) -> [WaypointCoord] {
        (0..<count).map { WaypointCoord(CLLocationCoordinate2D(latitude: home.latitude + Double($0) * step,
                                                               longitude: home.longitude)) }
    }

    /// A point `east` and `north` metres from home.
    private func offset(east: Double, north: Double) -> WaypointCoord {
        WaypointCoord(CLLocationCoordinate2D(
            latitude: home.latitude + north / 111_000,
            longitude: home.longitude + east / (111_000 * cos(home.latitude * .pi / 180))))
    }

    /// Points every `step` metres along straight lines through `corners`.
    private func dense(_ corners: [WaypointCoord], step: Double = 10) -> [WaypointCoord] {
        var out: [WaypointCoord] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let n = max(1, Int((metres(a, b) / step).rounded()))
            for i in 0..<n {
                let t = Double(i) / Double(n)
                out.append(WaypointCoord(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                                longitude: a.longitude + (b.longitude - a.longitude) * t)))
            }
        }
        if let last = corners.last { out.append(last) }
        return out
    }

    private func metres(_ a: WaypointCoord, _ b: WaypointCoord) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private func trimmed(_ waypoints: [WaypointCoord], isLoop: Bool = false,
                         extra: (start: Double, end: Double) = (0, 0)) throws -> SharedRouteTrim.Trimmed {
        let outcome = SharedRouteTrim.trim(waypoints, isLoop: isLoop, extra: extra)
        guard case .trimmed(let t) = outcome else {
            Issue.record("expected a trimmed route, got \(outcome)"); throw CancellationError()
        }
        return t
    }

    @Test("A straight walk publishes from the first point 200 m out to the last 200 m short, every 10 m")
    func straightWalk() throws {
        let path = line(101)                     // about 1,109 m, a point every 11.1 m
        let t = try trimmed(path)
        #expect(metres(t.waypoints[0], path[19]) < 0.001)                    // 210.8 m out
        #expect(metres(t.waypoints[t.waypoints.count - 1], path[81]) < 0.001) // 210.8 m short
        #expect(abs(t.keptMeters - 687.9) < 0.5)
        #expect(t.waypoints.count == 70)
        for (a, b) in zip(t.waypoints, t.waypoints.dropFirst()) { #expect(metres(a, b) <= 10.001) }
        #expect(abs(t.fullMeters - 1109.5) < 1)
    }

    @Test("The per-route extra comes off on top of the 200 m")
    func extraTrim() throws {
        let path = line(101)
        let t = try trimmed(path, extra: (50, 80))
        #expect(metres(t.waypoints[0], path[23]) < 0.001)                     // 255.2 m out
        #expect(metres(t.waypoints[t.waypoints.count - 1], path[74]) < 0.001) // 288.5 m short
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

    @Test("A walk that passes the door again publishes nothing near it")
    func twoLapsOfTheBlock() throws {
        let block = [offset(east: 0, north: 0), offset(east: 0, north: 200), offset(east: 200, north: 200),
                     offset(east: 200, north: 0), offset(east: 0, north: 0)]
        let path = dense(block + Array(block.dropFirst()))   // two laps, 1,600 m
        let t = try trimmed(path)
        for point in t.waypoints {
            #expect(metres(point, path[0]) >= 200)
            #expect(metres(point, path[path.count - 1]) >= 200)
        }
    }

    @Test("GPS jitter at the door doesn't count toward the 200 m")
    func jitterAtTheDoor() throws {
        let jitter = (0..<12).map { offset(east: $0 % 2 == 0 ? 12 : -12, north: 0) }
        let path = jitter + dense([offset(east: 0, north: 0), offset(east: 0, north: 1_000)])
        let t = try trimmed(path)
        #expect(t.waypoints.allSatisfy { metres($0, path[0]) >= 200 })
        #expect(metres(t.waypoints[0], offset(east: 0, north: 0)) >= 190)
    }

    @Test("A planned route's corner points are never published")
    func controlPointsRefused() {
        // RouteManager's suggested loop: home, then three corners of a square.
        let square = [offset(east: 0, north: 0), offset(east: 0, north: 400),
                      offset(east: 400, north: 400), offset(east: 400, north: 0)]
        #expect(SharedRouteTrim.trim(square, isLoop: true) == .notAPath)
        #expect(SharedRouteTrim.trim([offset(east: 0, north: 0), offset(east: 0, north: 1_200)], isLoop: false) == .notAPath)
    }

    @Test("Published points are respaced, so none is an original corner of the path")
    func respaced() throws {
        let path = dense([offset(east: 0, north: 0), offset(east: 0, north: 503), offset(east: 497, north: 503),
                          offset(east: 497, north: 0)], step: 37)
        let t = try trimmed(path)
        let corner = offset(east: 497, north: 503)
        #expect(t.waypoints.allSatisfy { metres($0, corner) > 0.5 || metres($0, t.waypoints[0]) < 0.001 })
        // Other phones follow it as a recorded line, not by asking for directions per point.
        #expect(RecordedRoute.isRecorded(t.waypoints.map(\.clCoordinate)))
    }

    @Test("A loop is closed first, so its way back is trimmed near home too")
    func loopClosesBeforeTrimming() throws {
        let out = dense([offset(east: 0, north: 0), offset(east: 0, north: 600), offset(east: 600, north: 600)])
        let t = try trimmed(out, isLoop: true)                // closes with a 849 m leg home
        #expect(t.waypoints.allSatisfy { metres($0, out[0]) >= 200 })
        #expect(abs(t.fullMeters - 2048.5) < 10)   // offset() is a flat-earth approximation
        let open = try trimmed(out, isLoop: false)
        #expect(t.keptMeters > open.keptMeters + 150)   // about 1,000 m against 800 m
    }

    @Test("Too short, or too little outside the zones, is not shared")
    func shortRoutes() throws {
        guard case .tooShort(let full) = SharedRouteTrim.trim(line(53), isLoop: false) else {
            Issue.record("577 m should be too short"); return
        }
        #expect(abs(full - 577) < 1)
        // 1.2 km of laps round a 100 m block never leaves the zone.
        let block = [offset(east: 0, north: 0), offset(east: 0, north: 100), offset(east: 100, north: 100),
                     offset(east: 100, north: 0), offset(east: 0, north: 0)]
        let laps = dense(block + Array(block.dropFirst()) + Array(block.dropFirst()))
        #expect(SharedRouteTrim.trim(laps, isLoop: false) == .tooFewPoints)
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
        let path = line(101)
        let a = try trimmed(path), b = try trimmed(path.flatMap { [$0, $0] })
        #expect(b.waypoints.count == a.waypoints.count)
        for (x, y) in zip(a.waypoints, b.waypoints) { #expect(metres(x, y) < 0.001) }
        #expect(b.waypoints.allSatisfy { $0.latitude.isFinite && $0.longitude.isFinite })
        #expect(zip(b.waypoints, b.waypoints.dropFirst()).allSatisfy { $0 != $1 })
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
        let path = dense([offset(east: 0, north: 0), offset(east: 0, north: 600), offset(east: 600, north: 600)])
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))   // no extra trim
        let route = CustomRoute(id: id, name: "Lake loop", waypoints: path, totalDistance: 2_400,
                                isLoop: true, createdAt: Date())
        let record = try CommunityRouteService.record(for: route)
        let json = try #require(record["waypointsJSON"] as? String)
        let published = try JSONDecoder().decode([WaypointCoord].self, from: Data(json.utf8))
        let t = try trimmed(path, isLoop: true)
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
        let route = CustomRoute(id: UUID(), name: "Block", waypoints: line(3), totalDistance: 22,
                                isLoop: false, createdAt: Date())
        #expect(throws: SharedRouteTrim.CannotShareError.self) { try CommunityRouteService.record(for: route) }
        let outcome = SharedRouteTrim.trim(route)
        #expect(!RouteSharePrivacyNote.canShare(outcome))
        #expect(RouteSharePrivacyNote.text(for: outcome, totalDistance: 22).hasPrefix("This route is too short to share."))
    }

    @Test("A suggested route shares one lap of its directions path, with an id from that path")
    func suggestedRouteSharesDirectionsPath() {
        func suggestion() -> SuggestedRoute {
            var coords = line(80).map(\.clCoordinate)
            return SuggestedRoute(polyline: MKPolyline(coordinates: &coords, count: coords.count),
                                  openInMapsItem: MKMapItem(location: CLLocation(latitude: home.latitude,
                                                                                 longitude: home.longitude),
                                                            address: nil),
                                  isLoop: true, bearing: 0, totalDistance: 3_000, totalTime: 1_800,
                                  lapCount: 2, label: nil,
                                  legWaypoints: [home, line(80)[79].clCoordinate])
        }
        let shared = suggestion().shareableRoute(name: "Loop")
        #expect(shared.waypoints.count == 80)
        for (a, b) in zip(shared.waypoints, line(80)) { #expect(metres(a, b) < 0.01) }
        #expect(shared.totalDistance == 1_500)
        #expect(suggestion().shareableRoute(name: "Again").id == shared.id, "same path, same cut")
        #expect(suggestion().toCustomRoute().waypoints.count == 2, "the private copy keeps its legs")
    }
}
