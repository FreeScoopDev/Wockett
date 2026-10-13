import Testing
import CloudKit
import CoreLocation
@testable import PoCSquat

/// A shared route goes public without its first and last 200 m, measured along
/// the path (2026-10-12 audit, finding 1). Distances are on a meridian, where a
/// thousandth of a degree of latitude is about 111 m, and checked with the same
/// ground distance the trim uses.
@MainActor
struct SharedRouteTrimTests {

    private let lon = -78.64

    /// `count` points north from 35.78°, `step` degrees apart.
    private func line(_ count: Int, step: Double = 0.001) -> [WaypointCoord] {
        (0..<count).map { WaypointCoord(CLLocationCoordinate2D(latitude: 35.78 + Double($0) * step, longitude: lon)) }
    }

    private func metres(_ a: WaypointCoord, _ b: WaypointCoord) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private func trimmed(_ waypoints: [WaypointCoord], isLoop: Bool = false) throws -> SharedRouteTrim.Trimmed {
        guard case .trimmed(let t) = SharedRouteTrim.trim(waypoints, isLoop: isLoop) else {
            Issue.record("expected a trimmed route"); throw CancellationError()
        }
        return t
    }

    @Test("The published path starts and ends exactly 200 m in")
    func exactMetres() throws {
        let path = line(11)                      // about 1,109 m
        let t = try trimmed(path)
        #expect(abs(metres(path[0], t.waypoints[0]) - 200) < 0.01)
        #expect(abs(metres(path[10], t.waypoints[t.waypoints.count - 1]) - 200) < 0.01)
        #expect(abs(t.keptMeters - (t.fullMeters - 400)) < 0.01)
        #expect(abs(t.fullMeters - 1109.5) < 1)
        // The two cut points plus the seven waypoints between 222 m and 888 m.
        #expect(t.waypoints.count == 9)
        #expect(t.waypoints[1] == path[2])
        #expect(t.waypoints[7] == path[8])
    }

    @Test("No published point lies within 200 m of either end")
    func nothingNearTheEnds() throws {
        let path = line(30, step: 0.0002)        // dense, like a recorded walk
        let t = try trimmed(path)
        for point in t.waypoints {
            #expect(metres(path[0], point) >= 199.99)
            #expect(metres(path[path.count - 1], point) >= 199.99)
        }
    }

    @Test("A loop is closed first, so its end is trimmed back from the start too")
    func loopClosesBeforeTrimming() throws {
        let path = [line(6)[0], line(6)[5]]      // out about 555 m, back via the closing leg
        let t = try trimmed(path, isLoop: true)
        #expect(abs(t.fullMeters - 1109.5) < 1)
        #expect(abs(metres(path[0], t.waypoints[0]) - 200) < 0.01)
        #expect(abs(metres(path[0], t.waypoints[t.waypoints.count - 1]) - 200) < 0.01)
        #expect(t.waypoints.count == 3)          // in, the far point, back
    }

    @Test("A loop that already returns to its start isn't closed twice")
    func closedLoopUnchanged() throws {
        let p = line(6)
        let t = try trimmed([p[0], p[5], p[0]], isLoop: true)
        #expect(abs(t.fullMeters - 1109.5) < 1)
    }

    @Test("Under 600 m is not shared; just over is")
    func shortRoutes() throws {
        guard case .tooShort(let full) = SharedRouteTrim.trim(line(2, step: 0.0053), isLoop: false) else {
            Issue.record("588 m should be too short"); return
        }
        #expect(abs(full - 588) < 1)
        let t = try trimmed(line(2, step: 0.0055)) // about 610 m
        #expect(abs(t.keptMeters - 210) < 1)
        #expect(t.waypoints.count == 2)
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
        let doubled = path.flatMap { [$0, $0] }
        let a = try trimmed(path), b = try trimmed(doubled)
        // Same points, give or take floating-point summing order (under a millimetre).
        #expect(b.waypoints.count == a.waypoints.count)
        for (x, y) in zip(a.waypoints, b.waypoints) { #expect(metres(x, y) < 0.001) }
        #expect(abs(b.keptMeters - a.keptMeters) < 0.001)
        #expect(b.waypoints.allSatisfy { $0.latitude.isFinite && $0.longitude.isFinite })
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
        let route = CustomRoute(id: UUID(), name: "Lake loop", waypoints: path, totalDistance: 1300,
                                isLoop: true, createdAt: Date())
        let record = try CommunityRouteService.record(for: route)
        let json = try #require(record["waypointsJSON"] as? String)
        let published = try JSONDecoder().decode([WaypointCoord].self, from: Data(json.utf8))
        let t = try trimmed(path, isLoop: true)
        #expect(published == t.waypoints)
        #expect(!published.contains(path[0]))
        #expect(record["isLoop"] as? Int == 0)
        let distance = try #require(record["distanceMeters"] as? Double)
        #expect(abs(distance - 1300 * t.keptMeters / t.fullMeters) < 0.001)
        #expect(distance < 1300)
        #expect(route.waypoints == path, "the copy the user keeps is untouched")
    }

    @Test("Publishing a too-short route throws before anything is written")
    func tooShortRecordThrows() {
        let route = CustomRoute(id: UUID(), name: "Block", waypoints: line(3), totalDistance: 222,
                                isLoop: false, createdAt: Date())
        #expect(throws: SharedRouteTrim.TooShortError.self) { try CommunityRouteService.record(for: route) }
        #expect(!RouteSharePrivacyNote.canShare(route))
        #expect(RouteSharePrivacyNote.text(for: route).hasPrefix("This route is too short to share."))
    }
}
