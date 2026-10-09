import Testing
import CoreLocation
import Foundation
@testable import PoCSquat

/// From the test audit of #163 (2026-10-09): each test catches a change to
/// the out-and-back code that TrailOutAndBackTests let through: the pace's
/// median, filters and floor, the stored choice, Head back's guards and
/// reset, a turned-round route's turnaround, the metric default, the caption,
/// and the live turnaround cue driven by GPS fixes.
@MainActor
struct TrailOutAndBackAuditTests {

    private func line(_ count: Int) -> [CLLocationCoordinate2D] {
        (0..<count).map { CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64 + Double($0) * 0.0011) }
    }

    private func walk(_ meters: Double, minutes: Double) -> WalkSession {
        WalkSession(id: UUID(), routeName: "w", date: Date(), elapsedTime: minutes * 60,
                    totalDistance: meters, waypoints: [], lapCount: 0, isLoop: false, activityType: "walking")
    }

    private func session(at along: Double, index: Int = 1) throws -> NavigationSessionManager {
        let coords = line(51)
        let plan = try #require(TrailWalkPlanner.plan(along: coords, isLoop: false, name: "Greenway",
                                                       from: coords[10], target: .roundTrip(meters: 2_000)))
        let route = plan.navigableRoute(activityMode: .walking)
        let mgr = NavigationSessionManager(route: route)
        mgr.writesSnapshots = false   // never the real crash snapshot from a unit test
        mgr.applySnapshot(ActiveWalkSnapshot(route: .init(route), startTime: Date().addingTimeInterval(-600),
                                             totalDistanceCovered: along, pausedDuration: 0, isPaused: false,
                                             pauseStartDate: nil, currentWaypointIndex: index, currentLap: 1,
                                             triggeredCheckpoints: [], splitTimes: [], liveSteps: 0,
                                             checkpointDate: Date(), trailAlong: along))
        return mgr
    }

    @Test("pace: median not mean (1.0, 1.1, 2.0 -> 1.1)")
    func paceMedian() {
        let h = [walk(1_800, minutes: 30), walk(1_980, minutes: 30), walk(3_600, minutes: 30)]
        #expect(TrailWalkOption.pace(for: .walking, history: h) == 1.1)
    }

    @Test("pace: short or brief walks are left out")
    func paceFilters() {
        let base = [walk(1_800, minutes: 30), walk(2_160, minutes: 30)]           // 1.0, 1.2
        // 400 m in 4 min (1.67) is under 500 m; 900 m in 4 min (3.75) is under 5 minutes.
        #expect(TrailWalkOption.pace(for: .walking, history: base + [walk(400, minutes: 4)]) == 1.2)
        #expect(TrailWalkOption.pace(for: .walking, history: [walk(1_800, minutes: 30), walk(900, minutes: 4)]) == 1.0)
        let tooShort = [walk(1_800, minutes: 30), walk(450, minutes: 6)]          // 1.0, 1.25
        #expect(TrailWalkOption.pace(for: .walking, history: tooShort) == 1.0)
    }

    @Test("pace: slow walks are raised to the floor")
    func paceFloor() {
        #expect(TrailWalkOption.pace(for: .walking, history: [walk(900, minutes: 30)]) == 0.7)
    }

    @Test("pace: only the most recent 20 count")
    func paceRecent() {
        let recent = (0..<20).map { _ in walk(1_800, minutes: 30) }               // 1.0
        let older = (0..<21).map { _ in walk(3_600, minutes: 30) }                // 2.0
        #expect(TrailWalkOption.pace(for: .walking, history: recent + older) == 1.0)
    }

    @Test("lastChosenTarget reads the stored choice, mode and pace")
    func lastChosen() throws {
        let suite = "audit.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        d.set(true, forKey: TrailWalkOption.byTimeKey)
        d.set("t20", forKey: TrailWalkOption.choiceKey)
        d.set(2.0, forKey: TrailWalkOption.paceKey(for: .walking))
        #expect(TrailWalkOption.lastChosenTarget(reach: 5_000, isLoop: false, activityMode: .walking, defaults: d)
                == .roundTrip(meters: 2_400))
    }

    @Test("Head back needs 50 m walked, and not after the walk is complete")
    func headBackGuards() throws {
        #expect(!(try session(at: 30)).canHeadBack)
        let mgr = try session(at: 600)
        mgr.isCompleted = true
        #expect(!mgr.canHeadBack)
    }

    @Test("Head back restarts the checkpoints and tells the view")
    func headBackResets() throws {
        let mgr = try session(at: 600, index: 4)
        var told: NavigableRoute?
        mgr.onRouteChanged = { told = $0 }
        let back = try #require(mgr.headBack())
        #expect(mgr.currentWaypointIndex == 1)
        #expect(told?.id == back.id)
    }

    @Test("Turned round, an out-and-back keeps its turnaround")
    func reversedKeepsTurnaround() throws {
        let coords = line(51)
        let plan = try #require(TrailWalkPlanner.plan(along: coords, isLoop: false, name: "G",
                                                       from: coords[10], target: .roundTrip(meters: 2_000)))
        let reversed = try #require(plan.navigableRoute(activityMode: .walking).reversedAlongLine())
        #expect(abs((reversed.turnaroundMeters ?? 0) - 1_000) < 3)
    }

    @Test("3 km is the metric default")
    func metricDefault() {
        let metric = TrailWalkOption.options(reach: 5_000, isLoop: true, byTime: false, usesMiles: false, metersPerSecond: 1.3)
        #expect(TrailWalkOption.defaultChoice(in: metric)?.id == "d3km")
    }

    @Test("Out-and-back caption names the turnaround distance")
    func outCaption() throws {
        let coords = line(51)
        let plan = try #require(TrailWalkPlanner.plan(along: coords, isLoop: false, name: "G",
                                                       from: coords[10], target: .roundTrip(meters: 2_000)))
        #expect(TrailText.startCaption(for: plan).hasPrefix("Out \(TrailText.distance(1_000)) and back"))
    }

    @Test("Walking past the turnaround marks it passed, live, from GPS fixes")
    func liveTurnaround() async throws {
        let mgr = try session(at: 900)
        #expect(!mgr.hasPassedTurnaround)
        let start = line(51)[10]
        for metres in stride(from: 910.0, through: 1_010.0, by: 10) {
            let lon = start.longitude + metres / 99.35 * 0.0011
            let fix = CLLocation(coordinate: .init(latitude: 35.78, longitude: lon), altitude: 0,
                                 horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
            mgr.locationManager(CLLocationManager(), didUpdateLocations: [fix])
            for _ in 0..<5 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(mgr.hasPassedTurnaround)
    }
}
