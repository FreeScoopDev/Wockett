import Testing
import CloudKit
import CoreLocation
import MapKit
import SwiftUI
@testable import PoCSquat

/// A shared route goes public as drawn, unless the user turns on Hide start
/// and finish: then only outside two privacy zones, circles around its start
/// and its end, each moved by the user's secret offset, with the real end at
/// least 200 m inside. Either way only a path is shared (never the points a
/// route was planned from), published every 10 m. Several cases model
/// someone trying to find the start from what was published. Paths run
/// from `home`; a ten-thousandth of a degree of latitude is about 11.1 m.
@MainActor
struct SharedRouteTrimTests {

    private let home = CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64)
    /// A fixed offset: 108 m to the east-south-east, radius extra 40 m.
    private let testOffset = SharePrivacyOffset(east: 90, north: -60, extra: 40)

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

    /// A point's metres east and north of home (the inverse of `offset`).
    private func xy(_ p: WaypointCoord) -> (east: Double, north: Double) {
        ((p.longitude - home.longitude) * 111_000 * cos(home.latitude * .pi / 180),
         (p.latitude - home.latitude) * 111_000)
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
                         offset: SharePrivacyOffset? = nil) throws -> SharedRouteTrim.Trimmed {
        let outcome = SharedRouteTrim.trim(waypoints, isLoop: isLoop, offset: offset ?? testOffset)
        guard case .trimmed(let t) = outcome else {
            Issue.record("expected a trimmed route, got \(outcome)"); throw CancellationError()
        }
        return t
    }

    // MARK: - Hide start and finish off (the default)

    @Test("With Hide start and finish off, the whole path is published as drawn")
    func toggleOffPublishesWholePath() throws {
        let path = dense([offset(east: 0, north: 0), offset(east: 0, north: 300), offset(east: 300, north: 300),
                          offset(east: 300, north: 0), offset(east: 0, north: 0)], step: 23)
        let route = CustomRoute(id: UUID(), name: "Block", waypoints: path, totalDistance: 3_600,
                                isLoop: true, createdAt: Date())
        // No offset needed, and a short loop round home is not refused.
        let record = try CommunityRouteService.record(for: route, hideEnds: false, offset: nil)
        let json = try #require(record["waypointsJSON"] as? String)
        let published = try JSONDecoder().decode([WaypointCoord].self, from: Data(json.utf8))
        #expect(metres(published[0], path[0]) < 0.01)
        #expect(metres(published[published.count - 1], path[path.count - 1]) < 0.01)
        for (a, b) in zip(published, published.dropFirst()) { #expect(metres(a, b) <= 10.001) }
        #expect(record["isLoop"] as? Int == 1)
        let distance = try #require(record["distanceMeters"] as? Double)
        #expect(abs(distance - 1_200) < 5)   // the path's length, not the route's 3,600
        guard case .trimmed(let t) = SharedRouteTrim.prepare(route, hideEnds: false, offset: nil) else {
            Issue.record("expected the whole path"); return
        }
        #expect(!t.hidesEnds)
        #expect(RouteSharePrivacyNote.text(for: .trimmed(t)).contains("whole route"))
        #expect(SharedRouteTrim.homeWarning.contains("where you live"))
    }

    @Test("With Hide start and finish off, a short route is shared, not refused")
    func toggleOffSharesShortRoutes() throws {
        let short = line(30)                      // about 320 m
        guard case .trimmed(let t) = SharedRouteTrim.prepare(short, isLoop: false, hideEnds: false, offset: nil) else {
            Issue.record("a short route should be shared whole"); return
        }
        #expect(!t.hidesEnds)
        #expect(abs(t.keptMeters - 321.6) < 1)
        // The same route with hiding on is too short.
        guard case .tooShort = SharedRouteTrim.prepare(short, isLoop: false, hideEnds: true, offset: testOffset) else {
            Issue.record("expected tooShort with hiding on"); return
        }
    }

    @Test("A route too long for one record is refused before anything is written")
    func tooLongRefused() {
        let long = line(11_000, step: 0.0002)    // about 244 km at 22 m
        #expect(SharedRouteTrim.prepare(long, isLoop: false, hideEnds: false, offset: nil) == .tooLong)
        let route = CustomRoute(id: UUID(), name: "Coast", waypoints: long, totalDistance: 244_000,
                                isLoop: false, createdAt: Date())
        #expect(throws: SharedRouteTrim.CannotShareError(outcome: .tooLong)) {
            try CommunityRouteService.record(for: route, hideEnds: false, offset: nil)
        }
    }

    @Test("With Hide start and finish off, a planned route's corners are still refused")
    func toggleOffStillNeedsAPath() {
        let square = [offset(east: 0, north: 0), offset(east: 0, north: 400),
                      offset(east: 400, north: 400), offset(east: 400, north: 0)]
        #expect(SharedRouteTrim.prepare(square, isLoop: true, hideEnds: false, offset: nil) == .notAPath)
        #expect(SharedRouteTrim.prepare([], isLoop: false, hideEnds: false, offset: nil) == .notAPath)
        let p = line(1)[0]
        #expect(SharedRouteTrim.prepare([p, p], isLoop: false, hideEnds: false, offset: nil) == .notAPath)
    }

    @Test("With Hide start and finish on, the offset trim is what is published")
    func toggleOnUsesTheTrim() {
        let path = line(136)
        // Equal to within CLLocation's own rounding, which varies between calls.
        guard case .trimmed(let viaPrepare) = SharedRouteTrim.prepare(path, isLoop: false, hideEnds: true,
                                                                       offset: testOffset),
              case .trimmed(let viaTrim) = SharedRouteTrim.trim(path, isLoop: false, offset: testOffset) else {
            Issue.record("expected a trimmed route"); return
        }
        #expect(viaPrepare.waypoints.count == viaTrim.waypoints.count)
        for (a, b) in zip(viaPrepare.waypoints, viaTrim.waypoints) { #expect(metres(a, b) < 0.01) }
        #expect(abs(viaPrepare.keptMeters - viaTrim.keptMeters) < 0.01)
        #expect(SharedRouteTrim.prepare(path, isLoop: false, hideEnds: true, offset: nil) == .offsetUnavailable)
        guard case .trimmed(let t) = SharedRouteTrim.prepare(path, isLoop: true, hideEnds: true, offset: testOffset) else {
            Issue.record("expected a trimmed route"); return
        }
        #expect(t.hidesEnds && !t.isLoop)
    }

    // MARK: - Someone looking for home

    @Test("Several loops from one home point at home + the offset, not at home")
    func attackerFindsOnlyTheFalseCentre() throws {
        // Four loops from the same door, one user, one offset. Both published
        // ends of a loop lie on one circle, so the centre lies on the
        // perpendicular bisector of the two ends; the least-squares meeting
        // point of the four bisectors is the attacker's best estimate.
        let loops: [[(Double, Double)]] = [
            [(0, 0), (0, 900), (700, 900), (700, 0), (0, 0)],
            [(0, 0), (-800, 0), (-800, -700), (0, -700), (0, 0)],
            [(0, 0), (0, 800), (-900, 800), (-900, 0), (0, 0)],
            [(0, 0), (900, 0), (900, -600), (0, -600), (0, 0)],
        ]
        var a11 = 0.0, a12 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0
        for loop in loops {
            let t = try trimmed(dense(loop.map { offset(east: $0.0, north: $0.1) }), isLoop: true)
            let s = xy(t.waypoints[0]), e = xy(t.waypoints[t.waypoints.count - 1])
            let d = (e.east - s.east, e.north - s.north)
            let rhs = d.0 * (s.east + e.east) / 2 + d.1 * (s.north + e.north) / 2
            a11 += d.0 * d.0; a12 += d.0 * d.1; a22 += d.1 * d.1; b1 += d.0 * rhs; b2 += d.1 * rhs
            #expect(t.waypoints.allSatisfy { metres($0, offset(east: 0, north: 0)) >= 200 })
        }
        let det = a11 * a22 - a12 * a12
        let estimate = ((b1 * a22 - b2 * a12) / det, (a11 * b2 - a12 * b1) / det)
        // The attacker works: it finds the zones' centre...
        #expect(hypot(estimate.0 - testOffset.east, estimate.1 - testOffset.north) < 25)
        // ...and that centre is not home. (Centred on home, as before, it was within 3 m.)
        #expect(hypot(estimate.0, estimate.1) >= 50)
    }

    @Test("A long straight segment through the zone publishes nothing inside it")
    func longSegmentThroughTheZone() throws {
        // Out north and east in 10 m steps, then one 1.7 km segment straight
        // back through the door and beyond, then on to the finish.
        let path = dense([offset(east: 0, north: 0), offset(east: 0, north: 600), offset(east: 600, north: 600)])
            + [offset(east: -600, north: -600)]
            + Array(dense([offset(east: -600, north: -600), offset(east: -600, north: -1_800)]).dropFirst())
        let t = try trimmed(path)
        let start = path[0], end = path[path.count - 1]
        #expect(t.waypoints.allSatisfy { metres($0, start) >= 200 && metres($0, end) >= 200 })
        for (a, b) in zip(t.waypoints, t.waypoints.dropFirst()) { #expect(metres(a, b) <= 10.001) }
    }

    @Test("The zone is moved by the offset: a line along it loses more at one end")
    func zoneFollowsTheOffset() throws {
        let path = line(136)                     // about 1,500 m north
        let south = SharePrivacyOffset(east: 0, north: -100, extra: 5)
        let t = try trimmed(path, offset: south)
        // Start: the centre is 100 m behind the walker, radius 305 m: 205 m off.
        let first = metres(t.waypoints[0], path[0])
        #expect(first >= 205 && first < 215)
        // End: the centre is 100 m back along the line: 405 m off.
        let last = metres(t.waypoints[t.waypoints.count - 1], path[path.count - 1])
        #expect(last >= 404 && last < 415)
        // Sideways: radius 300 m around a point 100 m east, 283 m along the line.
        let east = try trimmed(path, offset: SharePrivacyOffset(east: 100, north: 0, extra: 0))
        let firstEast = metres(east.waypoints[0], path[0])
        #expect(firstEast >= 282 && firstEast < 293)
    }

    @Test("A walk that passes the door again publishes nothing near it")
    func twoLapsOfTheBlock() throws {
        let block = [offset(east: 0, north: 0), offset(east: 0, north: 500), offset(east: 500, north: 500),
                     offset(east: 500, north: 0), offset(east: 0, north: 0)]
        let path = dense(block + Array(block.dropFirst()))   // two laps, 4,000 m
        let t = try trimmed(path)
        #expect(t.waypoints.allSatisfy { metres($0, path[0]) >= 200 && metres($0, path[path.count - 1]) >= 200 })
    }

    @Test("GPS jitter at the door doesn't count toward the 200 m")
    func jitterAtTheDoor() throws {
        let jitter = (0..<12).map { offset(east: $0 % 2 == 0 ? 12 : -12, north: 0) }
        let path = jitter + dense([offset(east: 0, north: 0), offset(east: 0, north: 1_500)])
        let t = try trimmed(path)
        #expect(t.waypoints.allSatisfy { metres($0, offset(east: 0, north: 0)) >= 190 })
    }

    @Test("A loop round one 200 m block is refused, not shared as a stub")
    func blockLoopRefused() {
        let block = [offset(east: 0, north: 0), offset(east: 0, north: 200), offset(east: 200, north: 200),
                     offset(east: 200, north: 0), offset(east: 0, north: 0)]
        let outcome = SharedRouteTrim.trim(dense(block), isLoop: true, offset: testOffset)
        guard case .tooShort = outcome else { Issue.record("expected tooShort, got \(outcome)"); return }
        // Three laps don't help: what's left is never 400 m in one stretch.
        let laps = dense(block + Array(block.dropFirst()) + Array(block.dropFirst()))
        guard case .tooShort = SharedRouteTrim.trim(laps, isLoop: true, offset: testOffset) else {
            Issue.record("three laps of the block should be refused"); return
        }
    }

    @Test("What's kept is at least 400 m and a quarter of the route, or nothing is")
    func keptFloor() throws {
        // 1.6 km out and back along one street: about 1,050 m of it is far enough out.
        let street = dense([offset(east: 0, north: 0), offset(east: 0, north: 800), offset(east: 0, north: 0)])
        let t = try trimmed(street)
        #expect(t.keptMeters >= 400 && t.keptMeters >= t.fullMeters / 4)
        // 900 m out and back: about 350 m would be left, so it isn't shared.
        let shorter = dense([offset(east: 0, north: 0), offset(east: 0, north: 450), offset(east: 0, north: 0)])
        guard case .tooShort = SharedRouteTrim.trim(shorter, isLoop: false, offset: testOffset) else {
            Issue.record("a stub under 400 m should be refused"); return
        }
    }

    // MARK: - The offset

    @Test("No offset, or one the store would never write, publishes nothing")
    func missingOffsetRefuses() throws {
        let path = line(136)
        #expect(SharedRouteTrim.trim(path, isLoop: false, offset: nil) == .offsetUnavailable)
        #expect(SharedRouteTrim.trim(path, isLoop: false,
                                     offset: SharePrivacyOffset(east: 10, north: 0, extra: 0)) == .offsetUnavailable)
        #expect(SharedRouteTrim.trim(path, isLoop: false,
                                     offset: SharePrivacyOffset(east: 100, north: 0, extra: .nan)) == .offsetUnavailable)
        let route = CustomRoute(id: UUID(), name: "Lane", waypoints: path, totalDistance: 1_500,
                                isLoop: false, createdAt: Date())
        #expect(throws: SharedRouteTrim.CannotShareError(outcome: .offsetUnavailable)) {
            try CommunityRouteService.record(for: route, hideEnds: true, offset: nil)
        }
        #expect(RouteSharePrivacyNote.text(for: .offsetUnavailable).contains("iCloud"))
    }

    @Test("Random offsets are 50-150 m with a 0-100 m extra, and differ")
    func randomOffsets() {
        let offsets = (0..<200).map { _ in SharePrivacyOffset.random() }
        #expect(offsets.allSatisfy { $0.isValid })
        #expect(Set(offsets.map(\.east)).count > 190)
    }

    private final class FakeBackend: SharePrivacyOffsetBackend {
        var stored: SharePrivacyOffset?
        var fetchError: Error?
        var fetches = 0
        var created: [SharePrivacyOffset] = []
        /// What another device stored first, returned instead of the new one.
        var storedElsewhere: SharePrivacyOffset?

        func fetch() async throws -> SharePrivacyOffset? {
            fetches += 1
            if let fetchError { throw fetchError }
            return stored
        }

        func create(_ offset: SharePrivacyOffset) async throws -> SharePrivacyOffset {
            created.append(offset)
            stored = storedElsewhere ?? offset
            return stored ?? offset
        }
    }

    @Test("When iCloud can't be reached, no offset is made on this device")
    func storeNeverMakesALocalOffset() async {
        let backend = FakeBackend()
        backend.fetchError = CKError(.networkUnavailable)
        let store = SharePrivacyOffsetStore(backend: backend, notifications: NotificationCenter())
        await #expect(throws: CKError.self) { try await store.current() }
        #expect(await store.currentIfAvailable() == nil)
        #expect(backend.created.isEmpty)
    }

    @Test("The stored offset is used everywhere; one is made only when none is stored")
    func storeUsesTheStoredOffset() async throws {
        let backend = FakeBackend()
        backend.stored = testOffset
        let store = SharePrivacyOffsetStore(backend: backend, notifications: NotificationCenter())
        #expect(try await store.current() == testOffset)
        #expect(try await store.current() == testOffset)
        #expect(backend.fetches == 1)
        #expect(backend.created.isEmpty)

        // None stored, and another device stores one at the same moment: its wins.
        let empty = FakeBackend()
        let other = SharePrivacyOffset(east: -70, north: 70, extra: 10)
        empty.storedElsewhere = other
        let fresh = SharePrivacyOffsetStore(backend: empty, notifications: NotificationCenter())
        #expect(try await fresh.current() == other)
        #expect(empty.created.count == 1 && empty.created[0].isValid)
    }

    @Test("Signing in to another iCloud account drops the cached offset")
    func storeForgetsOnAccountChange() async throws {
        let backend = FakeBackend()
        backend.stored = testOffset
        let center = NotificationCenter()
        let store = SharePrivacyOffsetStore(backend: backend, notifications: center)
        _ = try await store.current()
        center.post(name: .CKAccountChanged, object: nil)
        let other = SharePrivacyOffset(east: -70, north: 70, extra: 10)
        backend.stored = other
        #expect(try await store.current() == other)
        #expect(backend.fetches == 2)
    }

    @Test("The private record reads back only a valid offset")
    func offsetRecord() {
        let record = CKRecord(recordType: CloudKitSharePrivacyOffsetBackend.recordType)
        record["east"] = 90.0
        record["north"] = -60.0
        record["extra"] = 40.0
        #expect(CloudKitSharePrivacyOffsetBackend.offset(from: record) == testOffset)
        record["east"] = 0.0
        record["north"] = 0.0
        #expect(CloudKitSharePrivacyOffsetBackend.offset(from: record) == nil)
    }

    // MARK: - Paths

    @Test("A planned route's corner points are never published")
    func controlPointsRefused() {
        // RouteManager's suggested loop: home, then three corners of a square.
        let square = [offset(east: 0, north: 0), offset(east: 0, north: 400),
                      offset(east: 400, north: 400), offset(east: 400, north: 0)]
        #expect(SharedRouteTrim.trim(square, isLoop: true, offset: testOffset) == .notAPath)
        #expect(SharedRouteTrim.trim([offset(east: 0, north: 0), offset(east: 0, north: 1_200)],
                                     isLoop: false, offset: testOffset) == .notAPath)
    }

    @Test("Published points are every 10 m, so none is an original corner of the path")
    func respaced() throws {
        let path = dense([offset(east: 0, north: 0), offset(east: 0, north: 803), offset(east: 797, north: 803),
                          offset(east: 797, north: 0)], step: 37)
        let t = try trimmed(path)
        let corner = offset(east: 797, north: 803)
        #expect(t.waypoints.allSatisfy { metres($0, corner) > 0.5 })
        for (a, b) in zip(t.waypoints, t.waypoints.dropFirst()) { #expect(metres(a, b) <= 10.001) }
        // Other phones follow it as a recorded line, not by asking for directions per point.
        #expect(RecordedRoute.isRecorded(t.waypoints.map(\.clCoordinate)))
    }

    @Test("A loop is closed first, so its way back is trimmed near home too")
    func loopClosesBeforeTrimming() throws {
        let out = dense([offset(east: 0, north: 0), offset(east: 0, north: 900), offset(east: 900, north: 900)])
        let t = try trimmed(out, isLoop: true)                // closes with a 1,273 m leg home
        #expect(t.waypoints.allSatisfy { metres($0, out[0]) >= 200 })
        #expect(abs(t.fullMeters - 3_073) < 15)   // offset() is a flat-earth approximation
        let open = try trimmed(out, isLoop: false)
        #expect(t.keptMeters > open.keptMeters + 500)
    }

    @Test("Too short is not shared")
    func shortRoutes() {
        guard case .tooShort(let full) = SharedRouteTrim.trim(line(53), isLoop: false, offset: testOffset) else {
            Issue.record("577 m should be too short"); return
        }
        #expect(abs(full - 577) < 1)
        #expect(RouteSharePrivacyNote.text(for: .tooShort(fullMeters: full)).hasPrefix("This route is too short to share with its start and finish hidden."))
    }

    @Test("Empty, one point and all-duplicate routes are too short, not a crash")
    func degenerate() {
        let p = line(1)[0]
        #expect(SharedRouteTrim.trim([], isLoop: false, offset: testOffset) == .tooShort(fullMeters: 0))
        #expect(SharedRouteTrim.trim([p], isLoop: false, offset: testOffset) == .tooShort(fullMeters: 0))
        #expect(SharedRouteTrim.trim([p], isLoop: true, offset: testOffset) == .tooShort(fullMeters: 0))
        #expect(SharedRouteTrim.trim([p, p, p], isLoop: true, offset: testOffset) == .tooShort(fullMeters: 0))
    }

    @Test("Duplicate points change nothing: no NaN, no repeated point")
    func duplicates() throws {
        let path = line(136)
        let a = try trimmed(path), b = try trimmed(path.flatMap { [$0, $0] })
        #expect(b.waypoints.count == a.waypoints.count)
        for (x, y) in zip(a.waypoints, b.waypoints) { #expect(metres(x, y) < 0.01) }
        #expect(b.waypoints.allSatisfy { $0.latitude.isFinite && $0.longitude.isFinite })
        #expect(zip(b.waypoints, b.waypoints.dropFirst()).allSatisfy { $0 != $1 })
    }

    // MARK: - The public record

    @Test("The public record holds the trimmed path and its length, and is never a loop")
    func publicRecord() throws {
        let path = dense([offset(east: 0, north: 0), offset(east: 0, north: 900), offset(east: 900, north: 900)])
        let route = CustomRoute(id: UUID(), name: "Lake loop", waypoints: path, totalDistance: 9_000,
                                isLoop: true, createdAt: Date())
        let record = try CommunityRouteService.record(for: route, hideEnds: true, offset: testOffset)
        let json = try #require(record["waypointsJSON"] as? String)
        let published = try JSONDecoder().decode([WaypointCoord].self, from: Data(json.utf8))
        let t = try trimmed(path, isLoop: true)
        // Exactly the same points: trimming is a pure function, and JSON
        // round-trips a Double exactly.
        #expect(published == t.waypoints)
        #expect(published.allSatisfy { metres($0, path[0]) >= 200 })
        #expect(record["isLoop"] as? Int == 0)
        // The length of what is published, whatever the route's own distance says.
        #expect(record["distanceMeters"] as? Double == t.keptMeters)
    }

    @Test("Trimming doesn't depend on what CoreLocation measured before")
    func independentOfCoreLocationHistory() throws {
        // CLLocation.distance(from:) keeps a process-wide cache of the scale
        // at one latitude and reuses it for any point within 0.005° of it
        // (iOS 26.5 and 27 simulators), so its answer depends on whichever
        // distance any thread measured last. Measuring just south, then just
        // north, of home leaves that cache in two different states.
        let path = dense([offset(east: 0, north: 0), offset(east: 0, north: 900), offset(east: 900, north: 900)])
        func afterMeasuring(atLatitude latitude: Double) throws -> SharedRouteTrim.Trimmed {
            _ = CLLocation(latitude: latitude, longitude: home.longitude)
                .distance(from: CLLocation(latitude: latitude, longitude: home.longitude + 0.001))
            return try trimmed(path, isLoop: true)
        }
        let south = try afterMeasuring(atLatitude: home.latitude - 0.0049)
        let north = try afterMeasuring(atLatitude: home.latitude + 0.0049)
        #expect(south == north)
    }

    @Test("A saved three-lap suggestion shares one lap's path and that path's length")
    func multiLapDistance() throws {
        // Saved from a 3-lap suggestion: corners of one lap, the distance of three.
        let corners = [offset(east: 0, north: 0), offset(east: 0, north: 700), offset(east: 700, north: 700),
                       offset(east: 700, north: 0)]
        let saved = CustomRoute(id: UUID(), name: "Block x3", waypoints: corners, totalDistance: 8_400,
                                isLoop: true, createdAt: Date())
        let legPaths = [dense([corners[0], corners[1]]), dense([corners[1], corners[2]]),
                        dense([corners[2], corners[3]]), dense([corners[3], corners[0]])]
        let shared = try #require(SharedRouteTrim.shareRoute(planned: saved, legPaths: legPaths))
        #expect(abs(shared.totalDistance - 2_800) < 20)
        let record = try CommunityRouteService.record(for: shared, hideEnds: true, offset: testOffset)
        let distance = try #require(record["distanceMeters"] as? Double)
        #expect(distance < 2_800)
        // A leg that didn't load: nothing to share yet.
        #expect(SharedRouteTrim.shareRoute(planned: saved, legPaths: Array(legPaths.dropLast())) == nil)
        #expect(SharedRouteTrim.shareRoute(planned: saved, legPaths: Array(legPaths.dropLast()) + [[]]) == nil)
    }

    // MARK: - The share sheet's default and length sentence

    @Test("Hide start and finish is on for someone who never chose, and a stored choice is kept")
    func hideEndsDefaultsOnUnlessChosen() throws {
        // The sheet's own declaration: @AppStorage(hideEndsKey) = hideEndsDefault.
        let suite = "SharedRouteTrimTests.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        func setting() -> AppStorage<Bool> {
            AppStorage(wrappedValue: SharedRouteTrim.hideEndsDefault, SharedRouteTrim.hideEndsKey, store: store)
        }
        // Renaming the key would read everyone's stored "off" as never chosen.
        #expect(SharedRouteTrim.hideEndsKey == "wkt_routeShareHideEnds")
        #expect(store.object(forKey: SharedRouteTrim.hideEndsKey) == nil)
        #expect(setting().wrappedValue == true, "no stored choice must read as on")
        store.set(false, forKey: SharedRouteTrim.hideEndsKey)
        #expect(setting().wrappedValue == false, "someone who turned it off keeps it off")
        store.set(true, forKey: SharedRouteTrim.hideEndsKey)
        #expect(setting().wrappedValue == true)
    }

    @Test("When hiding shortens the route, the sheet says why, with both lengths")
    func lengthSentenceExplainsTheDifference() throws {
        let t = try trimmed(line(136))
        let shared = SharedRouteTrim.formatted(t.keptMeters), full = SharedRouteTrim.formatted(t.fullMeters)
        #expect(shared != full)
        #expect(RouteSharePrivacyNote.text(for: .trimmed(t))
                == "Start and end are left off, so the shared route is \(shared), not \(full).")
    }

    @Test("When the shared length is the route's own, the sheet gives that one length")
    func lengthSentenceGivesOneLengthWhenSame() {
        guard case .trimmed(let t) = SharedRouteTrim.prepare(line(136), isLoop: false, hideEnds: false,
                                                             offset: nil) else {
            Issue.record("expected the whole path"); return
        }
        let shared = SharedRouteTrim.formatted(t.keptMeters)
        let text = RouteSharePrivacyNote.text(for: .trimmed(t))
        #expect(text == "The whole route is shared: \(shared).")
        #expect(!text.contains("not "), "one length, nothing to explain")
    }

    @Test("A suggested route shares one lap of its directions path")
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
        #expect(suggestion().toCustomRoute().waypoints.count == 2, "the private copy keeps its legs")
    }
}
