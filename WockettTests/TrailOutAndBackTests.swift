import Testing
import CoreLocation
import Foundation
@testable import PoCSquat

/// Walking part of a long trail (2026-10-09): out and back by distance or
/// time, the turnaround, and "Head back now". Joe: "we can't expect the users
/// to complete the entire trail if they are long… It should be somewhat
/// seamless."
@MainActor
struct TrailOutAndBackTests {

    /// A straight line east from (35.78, -78.64): `count` points ~100 m apart.
    private func line(_ count: Int) -> [CLLocationCoordinate2D] {
        (0..<count).map { CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64 + Double($0) * 0.0011) }
    }

    /// A closed square ~400 m a side.
    private var square: [CLLocationCoordinate2D] {
        let a = CLLocationCoordinate2D(latitude: 35.780, longitude: -78.640)
        let b = CLLocationCoordinate2D(latitude: 35.780, longitude: -78.6356)
        let c = CLLocationCoordinate2D(latitude: 35.7836, longitude: -78.6356)
        let d = CLLocationCoordinate2D(latitude: 35.7836, longitude: -78.640)
        return [a, b, c, d, a]
    }

    private func close(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D, within meters: Double = 2) -> Bool {
        guard let a else { return false }
        return TrailWalkPlanner.meters(a, b) <= meters
    }

    // MARK: Planning

    @Test("A round trip on a long line goes out half the distance toward the farther end and comes back")
    func roundTripOnALongLine() throws {
        let coords = line(51)                                   // ~5 km
        let start = coords[10]                                  // 1 km from the west end
        let plan = try #require(TrailWalkPlanner.plan(along: coords, isLoop: false, name: "Greenway",
                                                       from: start, target: .roundTrip(meters: 2_000)))
        #expect(abs(plan.distanceMeters - 2_000) < 5)
        #expect(abs((plan.turnaroundMeters ?? 0) - 1_000) < 3)
        #expect(close(plan.path.first, start) && close(plan.path.last, start), "ends where it began")
        #expect(close(plan.waypoints.last, start), "the last checkpoint is the start")
        let farthest = plan.path.map(\.longitude).max() ?? 0
        #expect(farthest > start.longitude, "heads east, toward the farther end")
        #expect(!plan.turnsAtTrailEnd && !plan.isLoop)
    }

    @Test("A round trip longer than the trail turns at the trail's end")
    func roundTripTurnsAtTheEnd() throws {
        let coords = line(51)
        let plan = try #require(TrailWalkPlanner.plan(along: coords, isLoop: false, name: "Greenway",
                                                       from: coords[10], target: .roundTrip(meters: 20_000)))
        let toEnd = TrailWalkPlanner.length(Array(coords[10...]))
        #expect(plan.turnsAtTrailEnd)
        #expect(abs((plan.turnaroundMeters ?? 0) - toEnd) < 3)
        #expect(abs(plan.distanceMeters - 2 * toEnd) < 5)
    }

    @Test("A long loop can be walked out and back too; the whole target still goes round")
    func loopRoundTrip() throws {
        let part = try #require(TrailWalkPlanner.plan(along: square, isLoop: true, name: "Loop",
                                                       from: square[0], target: .roundTrip(meters: 600)))
        #expect(!part.isLoop && abs(part.distanceMeters - 600) < 5 && close(part.path.last, square[0]))
        let full = try #require(TrailWalkPlanner.plan(along: square, isLoop: true, name: "Loop", from: square[0]))
        #expect(full.isLoop && full.turnaroundMeters == nil)
    }

    @Test("The turnaround survives the crash snapshot; old snapshots decode without one")
    func snapshotKeepsTurnaround() throws {
        let plan = try #require(TrailWalkPlanner.plan(along: line(51), isLoop: false, name: "G",
                                                       from: line(51)[10], target: .roundTrip(meters: 2_000)))
        let data = try JSONEncoder().encode(ActiveWalkSnapshot.RouteData(plan.navigableRoute(activityMode: .walking)))
        let restored = try JSONDecoder().decode(ActiveWalkSnapshot.RouteData.self, from: data).navigableRoute
        #expect(restored.turnaroundMeters == plan.turnaroundMeters)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "turnaroundMeters")
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(ActiveWalkSnapshot.RouteData.self, from: old).navigableRoute.turnaroundMeters == nil)
    }

    // MARK: The choices

    @Test("Distance choices shorter than the whole trail, then the whole trail")
    func distanceOptions() {
        let long = TrailWalkOption.options(reach: 5_000, isLoop: false, byTime: false, usesMiles: true, metersPerSecond: 1.3)
        #expect(long.map(\.id) == ["d1mi", "d2mi", "d3mi", "d5mi", "whole"])
        #expect(long.last?.target == .roundTrip(meters: 10_000), "a line's whole trail is to the end and back")
        #expect(TrailWalkOption.defaultChoice(in: long)?.id == "d2mi")

        let short = TrailWalkOption.options(reach: 1_200, isLoop: false, byTime: false, usesMiles: true, metersPerSecond: 1.3)
        #expect(short.map(\.id) == ["d1mi", "whole"], "2 mi round trip is longer than the whole 2.4 km")
        #expect(TrailWalkOption.defaultChoice(in: short)?.id == "d1mi")

        let metric = TrailWalkOption.options(reach: 5_000, isLoop: true, byTime: false, usesMiles: false, metersPerSecond: 1.3)
        #expect(metric.map(\.id) == ["d2km", "d3km", "d5km", "d8km", "whole"])
        #expect(metric.last?.target == .whole && metric.last?.title.hasPrefix("Full loop") == true)
    }

    @Test("Time choices use the pace: 20 minutes at 1.3 m/s is a 1,560 m round trip")
    func timeOptions() {
        let options = TrailWalkOption.options(reach: 2_000, isLoop: false, byTime: true, usesMiles: true, metersPerSecond: 1.3)
        #expect(options.map(\.id) == ["t20", "t30", "t45", "whole"], "60 minutes is past the end and back")
        #expect(options.first?.target == .roundTrip(meters: 1_560))
        #expect(TrailWalkOption.defaultChoice(in: options)?.id == "t30")
    }

    @Test("Pace is the median of recent walks long enough to judge, within bounds; else a typical one")
    func pace() {
        func walk(_ meters: Double, minutes: Double, type: String = "walking", flagged: Bool = false) -> WalkSession {
            var s = WalkSession(id: UUID(), routeName: "w", date: Date(), elapsedTime: minutes * 60,
                                totalDistance: meters, waypoints: [], lapCount: 0, isLoop: false, activityType: type)
            s.flaggedPossibleVehicle = flagged
            return s
        }
        let history = [walk(1_800, minutes: 30), walk(2_160, minutes: 30), walk(2_520, minutes: 30),   // 1.0, 1.2, 1.4
                       walk(300, minutes: 10),                                                       // too short
                       walk(18_000, minutes: 30, flagged: true),                                     // a drive
                       walk(9_000, minutes: 30, type: "cycling")]                                    // not a walk
        #expect(TrailWalkOption.pace(for: .walking, history: history) == 1.2)
        #expect(TrailWalkOption.pace(for: .walking, history: []) == 1.3)
        #expect(TrailWalkOption.pace(for: .walking, history: [walk(5_400, minutes: 30)]) == 2.2, "3 m/s is no walk: capped")
        #expect(TrailWalkOption.pace(for: .cycling, history: history) == 5.0, "one ride: 5 m/s")
    }

    // MARK: The session

    private func session(at along: Double, target: Double = 2_000) throws -> NavigationSessionManager {
        let coords = line(51)
        let plan = try #require(TrailWalkPlanner.plan(along: coords, isLoop: false, name: "Greenway",
                                                       from: coords[10], target: .roundTrip(meters: target)))
        let route = plan.navigableRoute(activityMode: .walking)
        let mgr = NavigationSessionManager(route: route)
        mgr.writesSnapshots = false   // never the real crash snapshot from a unit test
        mgr.applySnapshot(ActiveWalkSnapshot(route: .init(route), startTime: Date().addingTimeInterval(-600),
                                             totalDistanceCovered: along, pausedDuration: 0, isPaused: false,
                                             pauseStartDate: nil, currentWaypointIndex: 1, currentLap: 1,
                                             triggeredCheckpoints: [], splitTimes: [], liveSteps: 0,
                                             checkpointDate: Date(), trailAlong: along))
        return mgr
    }

    @Test("The turnaround counts from 15 m short of it; no turnaround, never")
    func turnaroundRule() {
        #expect(!NavigationSessionManager.hasReachedTurnaround(along: 984, turnaround: 1_000))
        #expect(NavigationSessionManager.hasReachedTurnaround(along: 985, turnaround: 1_000))
        #expect(NavigationSessionManager.hasReachedTurnaround(along: 1_400, turnaround: 1_000))
        #expect(!NavigationSessionManager.hasReachedTurnaround(along: 5_000, turnaround: nil))
        #expect(!NavigationSessionManager.hasReachedTurnaround(along: nil, turnaround: 1_000))
    }

    @Test("Before the turnaround: Head back is offered and the turnaround is not passed")
    func beforeTurnaround() throws {
        let mgr = try session(at: 600)
        mgr.checkTurnaround()
        #expect(!mgr.hasPassedTurnaround)
        #expect(mgr.canHeadBack)
    }

    @Test("Restored at the turnaround, it is already passed (no second cue), and Head back is not offered")
    func restoredAtTurnaround() throws {
        let mgr = try session(at: 995)
        #expect(mgr.hasPassedTurnaround, "set by the restore itself, before any fix")
        #expect(!mgr.canHeadBack, "already on the way back")
        #expect(!(try session(at: 900)).hasPassedTurnaround)
    }

    @Test("Head back now: the rest of the walk is the trail back to the start, one walk throughout")
    func headBack() throws {
        let mgr = try session(at: 600)
        let start = line(51)[10]
        let back = try #require(mgr.headBack())
        #expect(abs(TrailWalkPlanner.length(back.path ?? []) - 600) < 3, "the way back is what was walked out")
        #expect(abs(back.totalDistance - 1_200) < 3, "the route is the whole walk: 600 out, 600 back")
        #expect(close(back.path?.last, start), "ends where the walk began")
        #expect(back.turnaroundMeters == nil && !back.isLoop)
        #expect(mgr.route.id == back.id && mgr.legStartDistance == 0, "the 20-80% markers keep counting the whole walk")
    }

    @Test("On the way back, Head back is never offered again, live or restored")
    func noHeadBackOnTheWayBack() throws {
        let mgr = try session(at: 600)
        let back = try #require(mgr.headBack())
        let restored = NavigationSessionManager(route: back)
        restored.writesSnapshots = false
        restored.applySnapshot(ActiveWalkSnapshot(route: .init(back), startTime: Date().addingTimeInterval(-900),
                                                  totalDistanceCovered: 700, pausedDuration: 0, isPaused: false,
                                                  pauseStartDate: nil, currentWaypointIndex: 1, currentLap: 1,
                                                  triggeredCheckpoints: [], splitTimes: [], liveSteps: 0,
                                                  checkpointDate: Date(), trailAlong: 100))
        #expect(!restored.canHeadBack, "100 m into the way back: offering it again would lead away from the start")
    }

    @Test("Head back is only for out-and-back walks: not a full loop, not a recorded route")
    func headBackOnlyOutAndBack() throws {
        let loop = try #require(TrailWalkPlanner.plan(along: square, isLoop: true, name: "Loop", from: square[0]))
        let route = loop.navigableRoute(activityMode: .walking)
        let mgr = NavigationSessionManager(route: route)
        mgr.writesSnapshots = false
        mgr.applySnapshot(ActiveWalkSnapshot(route: .init(route), startTime: Date().addingTimeInterval(-600),
                                             totalDistanceCovered: 800, pausedDuration: 0, isPaused: false,
                                             pauseStartDate: nil, currentWaypointIndex: 1, currentLap: 1,
                                             triggeredCheckpoints: [], splitTimes: [], liveSteps: 0,
                                             checkpointDate: Date(), trailAlong: 800))
        #expect(!mgr.canHeadBack)
    }

    @Test("On a 3 km round trip, each checkpoint sits where it is on the walk, not at its twin on the way out")
    func checkpointsOnTheRightLeg() throws {
        // Expected distances written out, not derived from the path: derived
        // ones shared the code's first-match bias and passed while the
        // 1,600 m checkpoint registered at 1,400 m on the way out (critic run
        // 2 of #163). Out 1,500 m: checkpoints every 750 m and one at the
        // turnaround, the same on the way back.
        let coords = line(51)
        let plan = try #require(TrailWalkPlanner.plan(along: coords, isLoop: false, name: "G",
                                                       from: coords[10], target: .roundTrip(meters: 3_000)))
        let progress = try #require(TrailProgress(route: plan.navigableRoute(activityMode: .walking)))
        let expected: [Double] = [0, 750, 1_500, 2_250, 3_000]
        #expect(progress.checkpointAlong.count == expected.count)
        for (got, want) in zip(progress.checkpointAlong, expected) {
            #expect(abs(got - want) < 5, "checkpoint at \(got) m, expected \(want) m")
        }
    }

    @Test("The pace stored for arriving at a trail is the activity's own: a run's pace never times a walk")
    func storedPacePerActivity() throws {
        let defaults = try #require(UserDefaults(suiteName: "TrailOutAndBackTests-\(UUID().uuidString)"))
        defaults.set(true, forKey: TrailWalkOption.byTimeKey)
        defaults.set("t30", forKey: TrailWalkOption.choiceKey)
        defaults.set(3.0, forKey: TrailWalkOption.paceKey(for: .running))
        let walk = TrailWalkOption.lastChosenTarget(reach: 20_000, isLoop: false, activityMode: .walking, defaults: defaults)
        #expect(walk == .roundTrip(meters: 30 * 60 * 1.3), "no walking pace stored: the typical 1.3 m/s")
        let run = TrailWalkOption.lastChosenTarget(reach: 20_000, isLoop: false, activityMode: .running, defaults: defaults)
        #expect(run == .roundTrip(meters: 30 * 60 * 3.0))
    }

    @Test("A recorded out-and-back whose way back runs 0.3 m beside its way out keeps its checkpoints on the way back")
    func recordedOutAndBackCheckpoints() throws {
        // 1,500 m out with a point every 5 m, then back 0.3 m to the side,
        // as a recording comes home. Checkpoints over the whole 3 km: 800,
        // 1,600, 2,400, and the end. A wide tie (0.5 m) put 1,600 at 1,400 on
        // the way out (critic run 3 of #163).
        let step = 5.0 / (111_320 * cos(35.78 * .pi / 180))
        let out = (0...300).map { CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64 + Double($0) * step) }
        let back = out.reversed().dropFirst().map {
            CLLocationCoordinate2D(latitude: $0.latitude + 0.3 / 111_320, longitude: $0.longitude)
        }
        let route = NavigableRoute(name: "Recorded", waypoints: out + back, lapCount: 1, isLoop: false,
                                   totalDistance: 3_000).followingRecordedLine()
        #expect(route.pathIsRecording)
        let progress = try #require(TrailProgress(route: route))
        #expect(progress.checkpointAlong.count >= 4)
        #expect(abs(progress.checkpointAlong[2] - 1_600) < 5, "got \(progress.checkpointAlong)")
    }

    @Test("Short loops start on the full loop; long loops on the usual round trip")
    func loopDefaults() {
        let park = TrailWalkOption.options(reach: 1_200, isLoop: true, byTime: false, usesMiles: true, metersPerSecond: 1.3)
        #expect(TrailWalkOption.defaultChoice(in: park)?.id == "whole", "a 1.5 mi park loop is walked round, as before")
        let mid = TrailWalkOption.options(reach: 2_500, isLoop: true, byTime: false, usesMiles: true, metersPerSecond: 1.3)
        #expect(TrailWalkOption.defaultChoice(in: mid)?.id == "whole", "a 3.1 mi loop too")
        let big = TrailWalkOption.options(reach: 8_000, isLoop: true, byTime: false, usesMiles: true, metersPerSecond: 1.3)
        #expect(TrailWalkOption.defaultChoice(in: big)?.id == "d2mi", "a 10 mi loop starts on 2 mi out and back")
    }

    @Test("End and back says it goes to the trail's end")
    func endAndBackCaption() throws {
        let coords = line(51)
        let whole = try #require(TrailWalkOption.options(reach: TrailWalkPlanner.length(Array(coords[10...])), isLoop: false,
                                                         byTime: false, usesMiles: true, metersPerSecond: 1.3).last)
        let plan = try #require(TrailWalkPlanner.plan(along: coords, isLoop: false, name: "G", from: coords[10],
                                                       target: whole.target))
        #expect(plan.turnsAtTrailEnd)
        #expect(TrailText.startCaption(for: plan).hasPrefix("To the trail's end and back"))
    }

}
