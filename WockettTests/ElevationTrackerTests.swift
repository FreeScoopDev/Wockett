import Testing
import Foundation
import CoreLocation
@testable import PoCSquat

/// Climb from GPS altitude (`feat/walk-elevation-gain`). The rules are in
/// `ElevationTracker.swift`; the summary's tile in `ActivitySummaryContent`.
struct ElevationTrackerTests {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Feeds altitudes a fix every `every` seconds, all at `accuracy`.
    private func feed(_ tracker: inout ElevationTracker, _ altitudes: [Double],
                      accuracy: Double = 5, from: TimeInterval = 0, every: TimeInterval = 5) {
        for (i, altitude) in altitudes.enumerated() {
            tracker.add(altitude: altitude, verticalAccuracy: accuracy,
                        at: start.addingTimeInterval(from + Double(i) * every))
        }
    }

    // MARK: - Tracker

    @Test(arguments: 0..<12)
    func flatGPSJitter_addsNothing(startingAt offset: Int) throws {
        // GPS altitude wandering up to 2.5 m either side of 100 m for twenty
        // minutes, the way it does on a flat walk. Every starting point of the
        // pattern: from the centre value alone a bare 3 m hysteresis passed,
        // and from an extreme it saved over 100 m of climb (critic, 2026-10-15).
        let jitter: [Double] = [0, 1.5, -1, 2.5, -2.5, 0.5, 2, -1.5, 1, -2, 2.5, -2.5]
        var tracker = ElevationTracker()
        feed(&tracker, (0..<240).map { 100 + jitter[($0 + offset) % jitter.count] })
        let totals = try #require(tracker.totals)
        #expect(totals.ascentMeters == 0)
        #expect(totals.descentMeters == 0)
    }

    @Test func alternatingTwoMetreNoise_addsNothing() throws {
        // ±2 m flipping every fix at 10 m accuracy, a kilometre of flat walking
        // at the 5 m distance filter: 396 m of "climb" without smoothing.
        var tracker = ElevationTracker()
        for i in 0..<200 {
            tracker.add(altitude: i.isMultiple(of: 2) ? 98 : 102, verticalAccuracy: 10,
                        at: start.addingTimeInterval(Double(i) * 5))
        }
        let totals = try #require(tracker.totals)
        #expect(totals.ascentMeters == 0)
        #expect(totals.descentMeters == 0)
    }

    @Test func steadyClimb_givesTheGain() throws {
        // 60 m up, a metre a fix, ending as the walk ends. The smoothing lags
        // two fixes (2 m here) and the last part-step under the 3 m
        // hysteresis can go uncounted; it never overstates.
        var tracker = ElevationTracker()
        feed(&tracker, (0...60).map { 200 + Double($0) })
        let totals = try #require(tracker.totals)
        #expect(totals.ascentMeters >= 60 - ElevationTracker.hysteresis - 2)
        #expect(totals.ascentMeters <= 60)
        #expect(totals.descentMeters == 0)
    }

    @Test func upAndDown_keepsGainAndLossApart() throws {
        // Up 40 m, a pause at the top, down 24 m, a pause at the bottom, in
        // 2 m steps.
        let up = stride(from: 0.0, through: 40, by: 2).map { 50 + $0 }
        let down = stride(from: 38.0, through: 16, by: -2).map { 50 + $0 }
        var tracker = ElevationTracker()
        feed(&tracker, up + Array(repeating: 90, count: 5) + down + Array(repeating: 66, count: 5))
        let totals = try #require(tracker.totals)
        #expect(totals.ascentMeters > 40 - ElevationTracker.hysteresis && totals.ascentMeters <= 40)
        #expect(totals.descentMeters > 24 - ElevationTracker.hysteresis && totals.descentMeters <= 24)
    }

    @Test func badVerticalAccuracy_isIgnored() throws {
        // A flat walk whose every other fix claims a 30 m spike, with an
        // accuracy that is unknown (negative) or worse than 15 m.
        var tracker = ElevationTracker()
        for i in 0..<40 {
            let t = start.addingTimeInterval(Double(i) * 5)
            tracker.add(altitude: 100, verticalAccuracy: 5, at: t)
            tracker.add(altitude: 130, verticalAccuracy: i.isMultiple(of: 2) ? -1 : 15.5,
                        at: t.addingTimeInterval(2))
        }
        let totals = try #require(tracker.totals)
        #expect(totals.ascentMeters == 0)
        #expect(totals.descentMeters == 0)
    }

    @Test func accuracyOfExactly15_counts() {
        var tracker = ElevationTracker()
        feed(&tracker, [100] + Array(repeating: 110, count: 5), accuracy: ElevationTracker.maxVerticalAccuracy)
        #expect(tracker.totals?.ascentMeters == 10)
    }

    @Test func noUsableFix_isNil_notZero() {
        // "No data" must never read as "flat".
        var tracker = ElevationTracker()
        #expect(tracker.totals == nil)
        feed(&tracker, [100, 140, 180], accuracy: 40)
        tracker.add(altitude: 100, verticalAccuracy: -1, at: start)
        #expect(tracker.totals == nil)
    }

    @Test func aGapInFixes_doesNotInventAJump() throws {
        // Flat at 100 m, then no usable fix for five minutes, then flat at
        // 150 m: the 50 m between is not a climb anyone recorded.
        var tracker = ElevationTracker()
        feed(&tracker, Array(repeating: 100, count: 10))
        feed(&tracker, Array(repeating: 150, count: 10), from: 45 + 300)
        let totals = try #require(tracker.totals)
        #expect(totals.ascentMeters == 0)
        #expect(totals.descentMeters == 0)
    }

    @Test func aStretchTheDistanceSkipped_isNotClimbEither() throws {
        // The walk ignores a 100 m+ jump in position; the altitude across it
        // is not counted, even with no gap in time.
        var tracker = ElevationTracker()
        feed(&tracker, Array(repeating: 100, count: 5))
        tracker.add(altitude: 140, verticalAccuracy: 5, at: start.addingTimeInterval(25), continuous: false)
        feed(&tracker, Array(repeating: 146, count: 5), from: 30)
        let totals = try #require(tracker.totals)
        #expect(totals.ascentMeters == 4)   // 140 to 146 counts; 100 to 140 does not
        #expect(totals.descentMeters == 0)
    }

    @Test func aSkippedStretch_onAFixWithBadAltitude_stillRestartsTheLevel() throws {
        // The jump lands on a fix whose altitude is unusable; the next good
        // fix is past the jump and must not be compared with before it.
        var tracker = ElevationTracker()
        feed(&tracker, Array(repeating: 100, count: 5))
        tracker.add(altitude: 140, verticalAccuracy: -1, at: start.addingTimeInterval(25), continuous: false)
        feed(&tracker, Array(repeating: 146, count: 5), from: 30)
        let totals = try #require(tracker.totals)
        #expect(totals.ascentMeters == 0)
    }

    @Test func restoring_keepsTheTotals_andReanchorsAtTheNextFix() throws {
        var tracker = ElevationTracker(restoring: ElevationTotals(ascentMeters: 42, descentMeters: 17))
        #expect(tracker.totals == ElevationTotals(ascentMeters: 42, descentMeters: 17))
        // The first fix after a restore sets the level; only the climb after it counts.
        feed(&tracker, [300] + Array(repeating: 310, count: 5))
        let totals = try #require(tracker.totals)
        #expect(totals.ascentMeters == 52)
        #expect(totals.descentMeters == 17)
        #expect(ElevationTracker(restoring: nil).totals == nil)
    }

    // MARK: - Session manager

    private func route(_ mode: ActivityMode) -> NavigableRoute {
        NavigableRoute(name: "Free", waypoints: [], lapCount: 1, isLoop: false,
                       totalDistance: 0, activityMode: mode)
    }

    @MainActor private func climb(_ mgr: NavigationSessionManager, _ altitudes: [Double]) {
        mgr.writesSnapshots = false
        for (i, altitude) in altitudes.enumerated() {
            mgr.recordElevation(altitude: altitude, verticalAccuracy: 5,
                                at: start.addingTimeInterval(Double(i) * 5), continuous: i > 0)
        }
    }

    @Test @MainActor func ride_isSavedWithItsClimb() throws {
        let mgr = NavigationSessionManager(route: route(.cycling))
        climb(mgr, Array(repeating: 10, count: 5) + Array(repeating: 30, count: 5) + Array(repeating: 15, count: 5))
        let elevation = try #require(mgr.completedSession.elevation)
        #expect(elevation == ElevationTotals(ascentMeters: 20, descentMeters: 12))
    }

    @Test @MainActor func locationFixes_feedTheClimb() async throws {
        // The delegate path itself, not recordElevation: removing the call in
        // didUpdateLocations must turn this red (critic, 2026-10-15).
        let mgr = NavigationSessionManager(route: route(.walking))
        mgr.writesSnapshots = false
        mgr.speaksSplits = false
        let manager = CLLocationManager()
        for i in 0..<12 {
            let loc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 45 + Double(i) * 0.00005, longitude: -75),
                                 altitude: i < 6 ? 100 : 120, horizontalAccuracy: 5, verticalAccuracy: 5,
                                 timestamp: start.addingTimeInterval(Double(i) * 5))
            mgr.locationManager(manager, didUpdateLocations: [loc])
        }
        // Each fix hops to the main actor in a task of its own.
        for _ in 0..<300 where mgr.elevationTracker.totals?.ascentMeters != 20 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mgr.elevationTracker.totals == ElevationTotals(ascentMeters: 20, descentMeters: 0))
    }

    @Test @MainActor func walkWithNoUsableAltitude_isSavedWithNil() {
        let mgr = NavigationSessionManager(route: route(.walking))
        mgr.writesSnapshots = false
        mgr.recordElevation(altitude: 100, verticalAccuracy: -1, at: start, continuous: false)
        #expect(mgr.completedSession.elevation == nil)
    }

    @Test @MainActor func climb_survivesACrashRestore() throws {
        let mgr = NavigationSessionManager(route: route(.running))
        climb(mgr, Array(repeating: 100, count: 5) + Array(repeating: 120, count: 5) + Array(repeating: 110, count: 5))
        let snapshot = mgr.snapshot
        #expect(snapshot.elevation == ElevationTotals(ascentMeters: 20, descentMeters: 8))

        let data = try JSONEncoder().encode(snapshot)
        let restored = NavigationSessionManager(route: route(.running))
        restored.writesSnapshots = false
        restored.speaksSplits = false
        restored.applySnapshot(try JSONDecoder().decode(ActiveWalkSnapshot.self, from: data))
        #expect(restored.elevationTracker.totals == ElevationTotals(ascentMeters: 20, descentMeters: 8))
        #expect(restored.completedSession.elevation == ElevationTotals(ascentMeters: 20, descentMeters: 8))
    }

    @Test func checkpointFromBeforeElevation_decodesWithNone() throws {
        let snapshot = ActiveWalkSnapshot(
            route: .init(route(.walking)), startTime: start, totalDistanceCovered: 500,
            pausedDuration: 0, isPaused: false, pauseStartDate: nil, currentWaypointIndex: 1,
            currentLap: 1, triggeredCheckpoints: [], splitTimes: [], liveSteps: 0,
            checkpointDate: start, elevation: ElevationTotals(ascentMeters: 9, descentMeters: 3))
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(json["elevation"] != nil)
        json.removeValue(forKey: "elevation")
        let old = try JSONDecoder().decode(ActiveWalkSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.elevation == nil)
    }

    @Test func salvagedWalk_keepsItsClimb_butIndoorNever() {
        func snapshot(_ mode: ActivityMode) -> ActiveWalkSnapshot {
            ActiveWalkSnapshot(
                route: .init(route(mode)), startTime: start, totalDistanceCovered: 500,
                pausedDuration: 0, isPaused: false, pauseStartDate: nil, currentWaypointIndex: 1,
                currentLap: 1, triggeredCheckpoints: [], splitTimes: [], liveSteps: 0,
                checkpointDate: start, elevation: ElevationTotals(ascentMeters: 9, descentMeters: 3))
        }
        #expect(ActiveWalkStore.salvagedSession(from: snapshot(.walking)).elevation
                == ElevationTotals(ascentMeters: 9, descentMeters: 3))
        #expect(ActiveWalkStore.salvagedSession(from: snapshot(.stationary)).elevation == nil)
    }

    @Test func codableSessionFromBefore117_decodesWithNoClimb() throws {
        let session = WalkSession(id: UUID(), routeName: "Walk", date: start, elapsedTime: 400,
                                  totalDistance: 1200, waypoints: [], lapCount: 1, isLoop: false,
                                  elevation: ElevationTotals(ascentMeters: 30, descentMeters: 30))
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        #expect(json["elevation"] != nil)
        json.removeValue(forKey: "elevation")
        let old = try JSONDecoder().decode(WalkSession.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.elevation == nil)
    }

    @Test func walkSession_roundTripsClimb_throughItsRecord() {
        let climb = ElevationTotals(ascentMeters: 123.5, descentMeters: 98.25)
        let session = WalkSession(id: UUID(), routeName: "Hill", date: start, elapsedTime: 1800,
                                  totalDistance: 4000, waypoints: [], lapCount: 1, isLoop: false,
                                  activityType: "cycling", elevation: climb)
        let record = WalkSessionRecord(from: session)
        #expect(!record.elevationData.isEmpty)
        #expect(record.toWalkSession().elevation == climb)
    }

    @Test func recordFromBeforeElevation_hasNoClimb() {
        let session = WalkSession(id: UUID(), routeName: "Walk", date: start, elapsedTime: 400,
                                  totalDistance: 1200, waypoints: [], lapCount: 1, isLoop: false,
                                  elevation: ElevationTotals(ascentMeters: 30, descentMeters: 30))
        let record = WalkSessionRecord(from: session)
        record.elevationData = Data()   // the field's default on an old record
        #expect(record.toWalkSession().elevation == nil)
        // A walk saved with no usable altitude stores the default too.
        let flat = WalkSession(id: UUID(), routeName: "Walk", date: start, elapsedTime: 400,
                               totalDistance: 1200, waypoints: [], lapCount: 1, isLoop: false)
        #expect(WalkSessionRecord(from: flat).elevationData.isEmpty)
    }

    // MARK: - Summary tile

    private func session(_ type: String, ascent: Double?, descent: Double = 0) -> WalkSession {
        WalkSession(id: UUID(), routeName: "x", date: start, elapsedTime: 1200, totalDistance: 2000,
                    waypoints: [], lapCount: 1, isLoop: false, activityType: type,
                    elevation: ascent.map { ElevationTotals(ascentMeters: $0, descentMeters: descent) })
    }

    @Test func climbTile_showsFromFiveMetres_forWalksRunsAndRides() {
        for type in ["walking", "running"] {
            #expect(ActivitySummaryContent.stats(for: session(type, ascent: 5))
                    == [.distance, .time, .pace, .steps, .climb])
            #expect(ActivitySummaryContent.stats(for: session(type, ascent: 4.9))
                    == [.distance, .time, .pace, .steps])
        }
        #expect(ActivitySummaryContent.stats(for: session("cycling", ascent: 80))
                == [.distance, .time, .speed, .climb])
    }

    @Test func climbTile_neverForNilOrIndoor() {
        #expect(!ActivitySummaryContent.stats(for: session("walking", ascent: nil)).contains(.climb))
        #expect(!ActivitySummaryContent.stats(for: session("stationary", ascent: 50)).contains(.climb))
        #expect(SummaryStat.climb.value(for: session("walking", ascent: nil)) == "—")
        #expect(SummaryStat.climb.detail(for: session("walking", ascent: nil)) == nil)
    }

    @Test func climbTile_metresOrFeet_withTheDescentAsDetail() {
        let walk = session("walking", ascent: 120.4, descent: 98.6)
        #expect(SummaryStat.climb.value(for: walk, metric: true) == "120 m")
        #expect(SummaryStat.climb.detail(for: walk, metric: true) == "↓ 99 m")
        #expect(SummaryStat.climb.value(for: walk, metric: false) == "395 ft")
        #expect(SummaryStat.climb.detail(for: walk, metric: false) == "↓ 323 ft")
        #expect(SummaryStat.climb.accessibilityDetail(for: walk, metric: true) == "99 m descent")
        #expect(SummaryStat.pace.detail(for: walk) == nil)
        #expect(SummaryStat.heightText(310, metric: false) == "\(1017.formatted()) ft")
    }

    @Test func statTiles_rows() {
        #expect(ActivityStatTiles.rows(count: 2) == [[0, 1]])
        #expect(ActivityStatTiles.rows(count: 3) == [[0, 1, 2]])
        #expect(ActivityStatTiles.rows(count: 4) == [[0, 1], [2, 3]])
        #expect(ActivityStatTiles.rows(count: 5) == [[0, 1, 2], [3, 4]])
    }
}
