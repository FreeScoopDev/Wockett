import Testing
import Foundation
import CoreLocation
@testable import PoCSquat

// Serialized because several tests write to the same shared file and would race
// under Swift Testing's default parallel execution.
@Suite(.serialized)
struct SnapshotRestoreTests {

    // Clear any leftover snapshot before each test (Swift Testing instantiates a new
    // struct per test, so this init acts as setUp).
    init() { ActiveWalkSnapshotStore.clear() }

    // MARK: - Helpers

    private func makeRoute(
        name: String = "Test Loop",
        waypoints: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: 37.77, longitude: -122.43),
            CLLocationCoordinate2D(latitude: 37.78, longitude: -122.44)
        ],
        activityMode: ActivityMode = .cycling,
        customRouteId: UUID? = nil
    ) -> NavigableRoute {
        NavigableRoute(
            name: name,
            waypoints: waypoints,
            lapCount: 3,
            isLoop: true,
            totalDistance: 5000,
            isCustomRoute: true,
            isCommunityRoute: false,
            activityMode: activityMode,
            customRouteId: customRouteId
        )
    }

    private func makeSnapshot(
        isPaused: Bool = false,
        pauseStartDate: Date? = nil,
        pausedDuration: TimeInterval = 90,
        checkpointDate: Date = Date()
    ) -> ActiveWalkSnapshot {
        ActiveWalkSnapshot(
            route: .init(makeRoute()),
            startTime: Date().addingTimeInterval(-1000),
            totalDistanceCovered: 1234.5,
            pausedDuration: pausedDuration,
            isPaused: isPaused,
            pauseStartDate: pauseStartDate,
            currentWaypointIndex: 3,
            currentLap: 2,
            triggeredCheckpoints: [1, 3],
            splitTimes: [
                .init(label: "20%", elapsed: 300),
                .init(label: "40%", elapsed: 600)
            ],
            liveSteps: 4200,
            checkpointDate: checkpointDate
        )
    }

    // MARK: - Snapshot Codable round-trip

    @Test func snapshot_codableRoundTrip() throws {
        let customId    = UUID()
        let pauseDate   = Date().addingTimeInterval(-50)
        let checkpoint  = Date().addingTimeInterval(-10)
        let startTime   = Date().addingTimeInterval(-1000)

        let route = makeRoute(
            name: "Full Encode Loop",
            waypoints: [
                CLLocationCoordinate2D(latitude: 37.77, longitude: -122.43),
                CLLocationCoordinate2D(latitude: 37.78, longitude: -122.44)
            ],
            activityMode: .cycling,
            customRouteId: customId
        )

        let original = ActiveWalkSnapshot(
            route: .init(route),
            startTime: startTime,
            totalDistanceCovered: 1234.5,
            pausedDuration: 90,
            isPaused: true,
            pauseStartDate: pauseDate,
            currentWaypointIndex: 3,
            currentLap: 2,
            triggeredCheckpoints: [1, 3],
            splitTimes: [
                .init(label: "20%",      elapsed: 300),
                .init(label: "WP 2/5",   elapsed: 720)
            ],
            liveSteps: 4200,
            checkpointDate: checkpoint
        )

        let data    = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ActiveWalkSnapshot.self, from: data)

        // Route fields
        #expect(decoded.route.name              == "Full Encode Loop")
        #expect(decoded.route.waypoints.count   == 2)
        #expect(abs(decoded.route.waypoints[0].latitude  - 37.77)   < 0.0001)
        #expect(abs(decoded.route.waypoints[1].longitude - (-122.44)) < 0.0001)
        #expect(decoded.route.lapCount          == 3)
        #expect(decoded.route.isLoop            == true)
        #expect(decoded.route.totalDistance     == 5000)
        #expect(decoded.route.isCustomRoute     == true)
        #expect(decoded.route.isCommunityRoute  == false)
        #expect(decoded.route.activityMode      == "cycling")
        #expect(decoded.route.customRouteId     == customId)
        // Session fields
        #expect(abs(decoded.startTime.timeIntervalSince(startTime))       < 0.001)
        #expect(decoded.totalDistanceCovered    == 1234.5)
        #expect(decoded.pausedDuration          == 90)
        #expect(decoded.isPaused                == true)
        #expect(decoded.pauseStartDate != nil)
        #expect(abs(decoded.pauseStartDate!.timeIntervalSince(pauseDate)) < 0.001)
        #expect(decoded.currentWaypointIndex    == 3)
        #expect(decoded.currentLap              == 2)
        #expect(decoded.triggeredCheckpoints    == [1, 3])
        #expect(decoded.splitTimes.count        == 2)
        #expect(decoded.splitTimes[0].label     == "20%")
        #expect(decoded.splitTimes[0].elapsed   == 300)
        #expect(decoded.splitTimes[1].label     == "WP 2/5")
        #expect(decoded.liveSteps               == 4200)
        #expect(abs(decoded.checkpointDate.timeIntervalSince(checkpoint)) < 0.001)
    }

    // MARK: - RouteData ↔ NavigableRoute round-trip

    @Test func routeData_roundTrip_preservesAllFields() {
        let customId = UUID()
        let coords = [
            CLLocationCoordinate2D(latitude: 37.77, longitude: -122.43),
            CLLocationCoordinate2D(latitude: 37.78, longitude: -122.44)
        ]
        let route = NavigableRoute(
            name: "Park Loop",
            waypoints: coords,
            lapCount: 2,
            isLoop: true,
            totalDistance: 3500,
            isCustomRoute: true,
            isCommunityRoute: false,
            activityMode: .running,
            customRouteId: customId
        )

        let roundTripped = ActiveWalkSnapshot.RouteData(route).navigableRoute

        #expect(roundTripped.name           == "Park Loop")
        #expect(roundTripped.waypoints.count == 2)
        #expect(abs(roundTripped.waypoints[0].latitude  - 37.77)   < 0.0001)
        #expect(abs(roundTripped.waypoints[1].longitude - (-122.44)) < 0.0001)
        #expect(roundTripped.lapCount       == 2)
        #expect(roundTripped.isLoop         == true)
        #expect(roundTripped.totalDistance  == 3500)
        #expect(roundTripped.isCustomRoute  == true)
        #expect(roundTripped.isCommunityRoute == false)
        #expect(roundTripped.activityMode   == .running)
        #expect(roundTripped.customRouteId  == customId)
    }

    // MARK: - Unknown activityMode falls back to .walking

    @Test func routeData_unknownActivityModeFallsBackToWalking() throws {
        // Encode a valid snapshot, patch the JSON to an unrecognised activityMode, decode.
        let snapshot = makeSnapshot()
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(snapshot),
            options: []
        ) as! [String: Any]
        var routeDict = json["route"] as! [String: Any]
        routeDict["activityMode"] = "hoverboard"
        json["route"] = routeDict
        let patched = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(ActiveWalkSnapshot.self, from: patched)
        #expect(decoded.route.navigableRoute.activityMode == .walking)
    }

    // MARK: - Store: save / load / clear

    @Test func store_saveLoadClear() {
        defer { ActiveWalkSnapshotStore.clear() }

        let snapshot = makeSnapshot()
        ActiveWalkSnapshotStore.save(snapshot)

        #expect(ActiveWalkSnapshotStore.hasPending == true)

        let loaded = ActiveWalkSnapshotStore.load()
        #expect(loaded != nil)
        #expect(loaded?.totalDistanceCovered == snapshot.totalDistanceCovered)
        #expect(loaded?.currentWaypointIndex == snapshot.currentWaypointIndex)
        #expect(loaded?.liveSteps           == snapshot.liveSteps)
        #expect(loaded?.triggeredCheckpoints == snapshot.triggeredCheckpoints)

        ActiveWalkSnapshotStore.clear()
        #expect(ActiveWalkSnapshotStore.hasPending == false)
        #expect(ActiveWalkSnapshotStore.load()     == nil)
    }

    // MARK: - Expiry

    @Test func store_freshSnapshot_survives() {
        defer { ActiveWalkSnapshotStore.clear() }

        // checkpointDate 1 hour ago — well within the 4-hour window
        let snapshot = makeSnapshot(checkpointDate: Date().addingTimeInterval(-3600))
        ActiveWalkSnapshotStore.save(snapshot)

        #expect(ActiveWalkSnapshotStore.hasPending == true)
        #expect(ActiveWalkSnapshotStore.load() != nil)
    }

    @Test func store_staleSnapshot_notResumableButPreserved() {
        defer { ActiveWalkSnapshotStore.clear() }

        // checkpointDate 5 hours ago — beyond the 4-hour window
        let snapshot = makeSnapshot(checkpointDate: Date().addingTimeInterval(-5 * 3600))
        ActiveWalkSnapshotStore.save(snapshot)

        // Not offered for resume
        #expect(ActiveWalkSnapshotStore.load() == nil)
        #expect(ActiveWalkSnapshotStore.hasPending == false)
        // But file is still present for the salvage path
        #expect(ActiveWalkSnapshotStore.loadAnyAge() != nil)
    }

    // MARK: - restoredPausedDuration

    @Test func restoredPausedDuration_activeDeath() {
        // Died while walking (not paused): dead-time gap measured from checkpointDate.
        // 60s prior pauses + 300s gap = 360s
        let now        = Date()
        let checkpoint = now.addingTimeInterval(-300)
        let snapshot   = makeSnapshot(isPaused: false, pausedDuration: 60, checkpointDate: checkpoint)

        let result = NavigationSessionManager.restoredPausedDuration(for: snapshot, now: now)
        #expect(abs(result - 360) < 0.001)
    }

    @Test func restoredPausedDuration_pausedDeath() {
        // Died while paused: gap measured from pauseStartDate, not checkpointDate.
        // 60s prior pauses + 500s from pause start = 560s
        let now        = Date()
        let pauseStart = now.addingTimeInterval(-500)
        let checkpoint = now.addingTimeInterval(-400)
        let snapshot   = makeSnapshot(
            isPaused: true,
            pauseStartDate: pauseStart,
            pausedDuration: 60,
            checkpointDate: checkpoint
        )

        let result = NavigationSessionManager.restoredPausedDuration(for: snapshot, now: now)
        #expect(abs(result - 560) < 0.001)
    }

    @Test func restoredPausedDuration_pausedDeathNilPauseStartFallsBackToCheckpoint() {
        // Defensive: isPaused=true but pauseStartDate is nil → uses checkpointDate.
        // 60s prior pauses + 400s from checkpoint = 460s
        let now        = Date()
        let checkpoint = now.addingTimeInterval(-400)
        let snapshot   = makeSnapshot(
            isPaused: true,
            pauseStartDate: nil,
            pausedDuration: 60,
            checkpointDate: checkpoint
        )

        let result = NavigationSessionManager.restoredPausedDuration(for: snapshot, now: now)
        #expect(abs(result - 460) < 0.001)
    }

    @Test func restoredPausedDuration_elapsedHonestyInvariant() {
        // After restore the computed elapsed must equal what it was at checkpoint time —
        // dead time never leaks into elapsed.
        // Setup: startTime 1000s before checkpoint, 60s prior pauses, walk active at death.
        // elapsedAtCheckpoint = 1000 - 60 = 940s
        let now        = Date()
        let checkpoint = now.addingTimeInterval(-300)
        let startTime  = checkpoint.addingTimeInterval(-1000)

        let snapshot = ActiveWalkSnapshot(
            route: .init(NavigableRoute(
                name: "t", waypoints: [], lapCount: 1, isLoop: false, totalDistance: 0
            )),
            startTime: startTime,
            totalDistanceCovered: 0,
            pausedDuration: 60,
            isPaused: false,
            pauseStartDate: nil,
            currentWaypointIndex: 0,
            currentLap: 1,
            triggeredCheckpoints: [],
            splitTimes: [],
            liveSteps: 0,
            checkpointDate: checkpoint
        )

        let restoredPaused  = NavigationSessionManager.restoredPausedDuration(for: snapshot, now: now)
        let restoredElapsed = now.timeIntervalSince(startTime) - restoredPaused

        let elapsedAtCheckpoint = checkpoint.timeIntervalSince(startTime) - 60.0  // 940s
        #expect(abs(restoredElapsed - elapsedAtCheckpoint) < 0.001)
    }

    // MARK: - salvagedElapsed

    @Test func salvagedElapsed_activeDeath() {
        // Died while active: elapsed measured from startTime to checkpointDate, minus prior pauses.
        // 1000s walk - 60s pauses = 940s
        let now        = Date()
        let checkpoint = now.addingTimeInterval(-300)
        let startTime  = checkpoint.addingTimeInterval(-1000)
        let snapshot = makeSnapshot(isPaused: false, pausedDuration: 60, checkpointDate: checkpoint)
        // Override startTime via a fresh snapshot so the math uses our values.
        let s = ActiveWalkSnapshot(
            route: .init(makeRoute()),
            startTime: startTime,
            totalDistanceCovered: 500,
            pausedDuration: 60,
            isPaused: false,
            pauseStartDate: nil,
            currentWaypointIndex: 0,
            currentLap: 1,
            triggeredCheckpoints: [],
            splitTimes: [],
            liveSteps: 0,
            checkpointDate: checkpoint
        )
        let result = ActiveWalkSnapshotStore.salvagedElapsed(for: s)
        #expect(abs(result - 940) < 0.001)
    }

    @Test func salvagedElapsed_pausedDeath() {
        // Died while paused: elapsed freezes at pause start (not checkpoint).
        // startTime 1000s before checkpoint; pauseStart 200s before checkpoint; 60s prior pauses
        // elapsed = (1000-200) - 60 = 740s
        let now        = Date()
        let checkpoint = now.addingTimeInterval(-300)
        let pauseStart = checkpoint.addingTimeInterval(-200)
        let startTime  = checkpoint.addingTimeInterval(-1000)
        let s = ActiveWalkSnapshot(
            route: .init(makeRoute()),
            startTime: startTime,
            totalDistanceCovered: 500,
            pausedDuration: 60,
            isPaused: true,
            pauseStartDate: pauseStart,
            currentWaypointIndex: 0,
            currentLap: 1,
            triggeredCheckpoints: [],
            splitTimes: [],
            liveSteps: 0,
            checkpointDate: checkpoint
        )
        let result = ActiveWalkSnapshotStore.salvagedElapsed(for: s)
        #expect(abs(result - 740) < 0.001)
    }

    // MARK: - trackPoints round-trip

    @Test func snapshot_trackPointsRoundTrip() throws {
        let coordA = CLLocationCoordinate2D(latitude: 37.77, longitude: -122.43)
        let coordB = CLLocationCoordinate2D(latitude: 37.78, longitude: -122.44)
        let coordC = CLLocationCoordinate2D(latitude: 37.79, longitude: -122.45)

        let snapshot = ActiveWalkSnapshot(
            route: .init(makeRoute()),
            startTime: Date().addingTimeInterval(-500),
            totalDistanceCovered: 300,
            pausedDuration: 0,
            isPaused: false,
            pauseStartDate: nil,
            currentWaypointIndex: 0,
            currentLap: 1,
            triggeredCheckpoints: [],
            splitTimes: [],
            liveSteps: 400,
            checkpointDate: Date(),
            trackPoints: [WaypointCoord(coordA), WaypointCoord(coordB), WaypointCoord(coordC)]
        )

        // Round-trip with trackPoints present
        let data    = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ActiveWalkSnapshot.self, from: data)
        #expect(decoded.trackPoints?.count == 3)
        #expect(abs(decoded.trackPoints![0].latitude  - 37.77) < 0.0001)
        #expect(abs(decoded.trackPoints![2].longitude - (-122.45)) < 0.0001)

        // Decoding old JSON with no trackPoints key → nil (backward compatible)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "trackPoints")
        let patched = try JSONSerialization.data(withJSONObject: json)
        let legacy  = try JSONDecoder().decode(ActiveWalkSnapshot.self, from: patched)
        #expect(legacy.trackPoints == nil)
    }
}
