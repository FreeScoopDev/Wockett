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

    @Test("Restored at the turnaround, it is already passed, and Head back is no longer offered")
    func atTurnaround() throws {
        let mgr = try session(at: 995)
        mgr.checkTurnaround()
        #expect(mgr.hasPassedTurnaround)
        #expect(!mgr.canHeadBack, "already on the way back")
    }

    @Test("Head back now: the rest of the walk is the trail back to the start")
    func headBack() throws {
        let mgr = try session(at: 600)
        let start = line(51)[10]
        let back = try #require(mgr.headBack())
        #expect(abs(back.totalDistance - 600) < 3)
        #expect(close(back.path?.last, start), "ends where the walk began")
        #expect(back.turnaroundMeters == nil && !back.isLoop)
        #expect(mgr.route.id == back.id && mgr.legStartDistance == 600)
        #expect(!mgr.canHeadBack, "the new route has no way out left to cut short")
    }
}
