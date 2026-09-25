import Testing
import CoreLocation
import Foundation
@testable import PoCSquat

/// Guiding a trail walk: position along the trail, off-trail alerts, and
/// checkpoints that count by distance along the trail.
struct TrailGuideTests {

    private let origin = CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64)

    /// A point `east` and `north` metres from `origin`.
    private func at(east: Double, north: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: origin.latitude + north / 111_320,
                               longitude: origin.longitude + east / (111_320 * cos(origin.latitude * .pi / 180)))
    }

    /// 1 km due east, a vertex every 100 m.
    private var straight: [CLLocationCoordinate2D] { (0...10).map { at(east: Double($0) * 100, north: 0) } }

    /// A hairpin: 500 m east, then back west 40 m to the north of the way out.
    private var hairpin: [CLLocationCoordinate2D] {
        (0...5).map { at(east: Double($0) * 100, north: 0) } + (0...5).reversed().map { at(east: Double($0) * 100, north: 40) }
    }

    // MARK: Position

    @Test("Position along a straight trail, and distance off it")
    func straightPosition() throws {
        let guide = TrailGuide(path: straight)
        #expect(abs(guide.length - 1000) < 2)
        let p = try #require(guide.position(of: at(east: 350, north: 30)))
        #expect(abs(p.along - 350) < 2)
        #expect(abs(p.offset - 30) < 1)
    }

    @Test("Where the trail doubles back, the stretch being followed wins")
    func hairpinKeepsTheWayOut() throws {
        let guide = TrailGuide(path: hairpin)
        // 22 m north of the way out: nearer the way back (18 m) than the way out (22 m).
        let point = at(east: 250, north: 22)
        let fresh = try #require(guide.position(of: point))
        #expect(fresh.along > 500, "with no history, the nearest stretch is the way back")
        let following = try #require(guide.position(of: point, near: 240))
        #expect(abs(following.along - 250) < 3, "someone walking out stays on the way out")
    }

    @Test("A stretch that is clearly closer still wins over the one being followed")
    func clearShortcutWins() throws {
        let guide = TrailGuide(path: hairpin)
        let onTheWayBack = at(east: 200, north: 40)
        let p = try #require(guide.position(of: onTheWayBack, near: 150))
        #expect(p.along > 500, "40 m off the way out, 0 m off the way back: that is where they are")
    }

    // MARK: Off-trail alerts

    @Test("A short step off the trail never alerts")
    func briefExcursionIsIgnored() {
        var monitor = OffTrailMonitor()
        let start = Date()
        #expect(monitor.update(offset: 70, at: start) == nil)
        #expect(monitor.update(offset: 70, at: start + 15) == nil)
        #expect(monitor.update(offset: 10, at: start + 16) == nil, "back before 20 s")
        #expect(monitor.update(offset: 70, at: start + 30) == nil, "a new excursion starts its own clock")
        #expect(!monitor.isOffTrail)
    }

    @Test("Staying 50 m off for 20 s alerts once; being back for 5 s clears it")
    func leaveAndReturn() {
        var monitor = OffTrailMonitor()
        let start = Date()
        #expect(monitor.update(offset: 60, at: start) == nil)
        #expect(monitor.update(offset: 60, at: start + 20) == .left)
        #expect(monitor.update(offset: 80, at: start + 25) == nil, "one alert, not one per fix")
        #expect(monitor.isOffTrail)
        #expect(monitor.update(offset: 20, at: start + 30) == nil)
        #expect(monitor.update(offset: 20, at: start + 35) == .returned)
        #expect(!monitor.isOffTrail)
    }

    @Test("Hovering at the edge does not flicker: 40 m is not back")
    func hysteresis() {
        var monitor = OffTrailMonitor()
        let start = Date()
        _ = monitor.update(offset: 60, at: start)
        #expect(monitor.update(offset: 60, at: start + 21) == .left)
        #expect(monitor.update(offset: 40, at: start + 30) == nil)
        #expect(monitor.update(offset: 40, at: start + 60) == nil)
        #expect(monitor.isOffTrail)
    }

    @Test("Standing still off the trail still alerts: the clock advances it, not only new fixes")
    func standingStillOffTrail() throws {
        let path = straight
        var progress = try #require(TrailProgress(route: route(path: path, waypoints: [path[0], path[10]], loop: false)))
        let start = Date()
        #expect(progress.update(location: at(east: 300, north: 130), at: start, alertsEnabled: true) == nil)
        #expect(progress.tick(at: start + 10, alertsEnabled: true) == nil)
        #expect(progress.tick(at: start + 21, alertsEnabled: true) == .left, "no new fix, but 21 s off the trail")
        #expect(progress.tick(at: start + 22, alertsEnabled: false) == nil, "switched off, the clock stays quiet")
    }

    // MARK: Progress and checkpoints

    private func route(path: [CLLocationCoordinate2D], waypoints: [CLLocationCoordinate2D], loop: Bool) -> NavigableRoute {
        NavigableRoute(name: "Test Trail", waypoints: waypoints, lapCount: 1, isLoop: loop,
                       totalDistance: TrailWalkPlanner.length(path), path: path)
    }

    @Test("Checkpoints count once passed along the trail, even far off it")
    func checkpointsByProgress() throws {
        let path = straight
        var progress = try #require(TrailProgress(route: route(path: path, waypoints: [path[0], path[5], path[10]], loop: false)))
        #expect(abs(progress.checkpointAlong[1] - 500) < 2)
        // Walk up from the start: position follows on, it does not leap to a
        // stretch 470 m away on one fix.
        for east in [0.0, 200, 400] {
            _ = progress.update(location: at(east: east, north: 45), at: Date(), alertsEnabled: true)
        }
        _ = progress.update(location: at(east: 470, north: 45), at: Date(), alertsEnabled: true)
        #expect(!progress.hasReached(waypoint: 1), "30 m short of the checkpoint")
        _ = progress.update(location: at(east: 490, north: 45), at: Date(), alertsEnabled: true)
        #expect(progress.hasReached(waypoint: 1),
                "within 20 m along the trail counts, although the checkpoint is 45 m away in a straight line")
        #expect(abs(progress.remaining - 510) < 3)
        #expect(abs(progress.distanceAlong(toWaypoint: 2) - 510) < 3)
    }

    @Test("Wandering off near a later stretch does not count its checkpoints")
    func progressHoldsWhileOffTrail() throws {
        let path = straight
        var progress = try #require(TrailProgress(route: route(path: path, waypoints: [path[0], path[5], path[10]], loop: false)))
        _ = progress.update(location: at(east: 200, north: 0), at: Date(), alertsEnabled: true)
        _ = progress.update(location: at(east: 600, north: 70), at: Date(), alertsEnabled: true)
        #expect(abs((progress.along ?? 0) - 200) < 2, "70 m off the trail, progress stays where they left it")
        #expect(!progress.hasReached(waypoint: 1))
        #expect(abs((progress.offset ?? 0) - 70) < 1, "the way back still updates")
        _ = progress.update(location: at(east: 600, north: 10), at: Date(), alertsEnabled: true)
        #expect(abs((progress.along ?? 0) - 600) < 2, "back on the trail, progress moves again")
    }

    @Test("On a loop, the start is also the finish, at the full length")
    func loopFinishIsFullLength() throws {
        let a = at(east: 0, north: 0), b = at(east: 400, north: 0), c = at(east: 400, north: 400), d = at(east: 0, north: 400)
        let path = [a, b, c, d, a]
        var progress = try #require(TrailProgress(route: route(path: path, waypoints: [a, b, c], loop: true)))
        #expect(abs(progress.targetAlong(forWaypoint: 0) - progress.guide.length) < 0.001)
        #expect(!progress.hasReached(waypoint: 0))
        // Walk the loop in order; each fix follows on from the last.
        for point in [b, c, d, at(east: 0, north: 15)] {
            _ = progress.update(location: point, at: Date(), alertsEnabled: false)
        }
        #expect(progress.hasReached(waypoint: 0), "15 m from home, having come all the way round")
    }

    @Test("With alerts off, position still updates but nothing alerts")
    func alertsOff() throws {
        let path = straight
        var progress = try #require(TrailProgress(route: route(path: path, waypoints: [path[0], path[10]], loop: false)))
        let start = Date()
        #expect(progress.update(location: at(east: 100, north: 80), at: start, alertsEnabled: false) == nil)
        #expect(progress.update(location: at(east: 100, north: 80), at: start + 30, alertsEnabled: false) == nil)
        #expect(!progress.isOffTrail)
        #expect(abs((progress.offset ?? 0) - 80) < 1)
    }

    @Test("A route without a trail line has no trail progress")
    func notATrail() {
        let plain = NavigableRoute(name: "Loop", waypoints: straight, lapCount: 1, isLoop: false, totalDistance: 1000)
        #expect(TrailProgress(route: plain) == nil)
    }

    @Test("Real trail: walking off Tulip Poplar Trail and stopping 99 m away alerts")
    func realTrailOffAndStop() throws {
        let url = try #require(Bundle.main.url(forResource: "nc", withExtension: "wktpack"))
        let tulip = try #require(try BundledTrailSource(url: url).trail(id: 8502))
        let coords = tulip.coordinates
        let plan = try #require(TrailWalkPlanner.plan(for: tulip, name: tulip.displayName, from: coords[0]))
        var progress = try #require(TrailProgress(route: plan.navigableRoute(activityMode: .walking)))
        let start = Date()
        var t = start
        for point in coords[0...6] {
            #expect(progress.update(location: point, at: t, alertsEnabled: true) == nil)
            t += 5
        }
        // 130 m west of the seventh vertex, which is 99 m from the nearest part of the loop.
        let off = CLLocationCoordinate2D(latitude: 35.76092, longitude: -78.68922913534124)
        _ = progress.update(location: off, at: t, alertsEnabled: true)
        #expect((progress.offset ?? 0) > OffTrailMonitor.leaveMeters, "offset \(progress.offset ?? -1)")
        var event: OffTrailMonitor.Event?
        for second in 1...30 where event == nil {
            event = progress.tick(at: t + Double(second), alertsEnabled: true)
        }
        #expect(event == .left)
    }

    // MARK: Coming home, and short loops (2026-09-25 review of #67/#68)

    /// Out `out` metres east and back `gap` metres to the north: a recording
    /// of a walk down a street and home again.
    private func outAndBack(out: Double, gap: Double) -> [CLLocationCoordinate2D] {
        let steps = Int(out / 50)
        return (0...steps).map { at(east: Double($0) * 50, north: 0) }
            + (0...steps).reversed().map { at(east: Double($0) * 50, north: gap) }
    }

    @Test("An out-and-back recording counts the way home and finishes",
          arguments: [400.0, 1000.0], [3.0, 6.0, 12.0])
    func outAndBackFinishes(out: Double, gap: Double) throws {
        let path = outAndBack(out: out, gap: gap)
        let length = TrailWalkPlanner.length(path)
        let waypoints = TrailWalkPlanner.checkpoints(along: path, isLoop: false, length: length)
        var progress = try #require(TrailProgress(route: route(path: path, waypoints: waypoints, loop: false)))
        var index = 1
        var finished = false
        var lastAlong = 0.0
        // Out along y = 0, then home along y = gap, 5 m a fix with ±2 m of wobble.
        let fixes = stride(from: 0.0, through: out, by: 5).map { (east: $0, north: 0.0) }
            + stride(from: out, through: 0, by: -5).map { (east: $0, north: gap) }
        for (i, fix) in fixes.enumerated() {
            let wobble = i.isMultiple(of: 2) ? 2.0 : -2.0
            _ = progress.update(location: at(east: fix.east, north: fix.north + wobble), at: Date(), alertsEnabled: true)
            let along = progress.along ?? 0
            #expect(along >= lastAlong - 15, "went back from \(lastAlong) to \(along) at fix \(i)")
            lastAlong = max(lastAlong, along)
            let passed = progress.checkpointsToAdvance(from: index, waypointCount: waypoints.count)
            index += passed
            if index >= waypoints.count { finished = true; break }
        }
        #expect(finished, "gap \(gap) m: ended at along \(progress.along ?? -1) of \(length)")
    }

    /// A round loop of `length` metres, a vertex every 10 m, starting due south.
    private func circle(_ length: Double) -> [CLLocationCoordinate2D] {
        let r = length / (2 * .pi)
        let n = max(12, Int(length / 10))
        return (0...n).map { i in
            let t = Double(i) / Double(n) * 2 * .pi
            return at(east: r * sin(t), north: r - r * cos(t))
        }
    }

    /// Walks `path` point by point at `step`-metre fixes with ±3 m of wobble,
    /// advancing checkpoints as the session does. Returns whether the walk
    /// finished, whether it asked to turn round, and the checkpoints passed
    /// before either.
    private func walk(_ progress: inout TrailProgress, along points: [CLLocationCoordinate2D],
                      count: Int) -> (finished: Bool, turned: Bool, passed: Int) {
        var index = 1
        var passed = 0
        for (i, point) in points.enumerated() {
            let wobble = i.isMultiple(of: 2) ? 3.0 : -3.0
            let p = CLLocationCoordinate2D(latitude: point.latitude + wobble / 111_320, longitude: point.longitude)
            _ = progress.update(location: p, at: Date(), alertsEnabled: true)
            if progress.isWalkingBackward { return (false, true, passed) }
            let n = progress.checkpointsToAdvance(from: index, waypointCount: count)
            passed += n
            index += n
            if index >= count { index = 0 }
            if passed >= count { return (true, false, passed) }
        }
        return (false, false, passed)
    }

    @Test("Round loops of any size: walked forward they finish once, walked backward they turn round first",
          arguments: [150.0, 240.0, 300.0, 346.0, 400.0, 1000.0])
    func loopsBothWays(length: Double) throws {
        let ring = circle(length)
        var forward = try loopProgress(ring)
        let count = forward.checkpointAlong.count
        let there = walk(&forward, along: ring, count: count)
        #expect(there.finished && !there.turned, "forward \(length) m: \(there)")

        var backward = try loopProgress(ring)
        let back = walk(&backward, along: Array(ring.reversed()), count: count)
        #expect(back.turned && back.passed == 0, "backward \(length) m: \(back)")
    }

    @Test("One fix drifting toward a switchback's next leg does not leap progress there")
    func driftDoesNotLeap() throws {
        // 200 m east, 30 m north, 200 m back west: legs 30 m apart, both inside the look-ahead.
        let path = [at(east: 0, north: 0), at(east: 200, north: 0), at(east: 200, north: 30), at(east: 0, north: 30)]
        var progress = try #require(TrailProgress(route: route(path: path, waypoints: [path[0], path[3]], loop: false)))
        for east in stride(from: 0.0, through: 100, by: 5) {
            _ = progress.update(location: at(east: east, north: 0), at: Date(), alertsEnabled: true)
        }
        // 25 m north: 5 m from the leg back (330 m along), 25 m from the one being walked.
        _ = progress.update(location: at(east: 105, north: 25), at: Date(), alertsEnabled: true)
        #expect(abs((progress.along ?? 0) - 105) < 5, "along \(progress.along ?? -1): one fix is not a 225 m leap")
        _ = progress.update(location: at(east: 110, north: 0), at: Date(), alertsEnabled: true)
        #expect(abs((progress.along ?? 0) - 110) < 3)
    }

    @Test("A turn the session declines is forgotten, so position can still move")
    func declinedTurnIsForgotten() throws {
        var progress = try loopProgress(squareLoop)
        for north in stride(from: 0.0, through: 60, by: 5) where !progress.isWalkingBackward {
            _ = progress.update(location: at(east: 0, north: north), at: Date(), alertsEnabled: true)
        }
        #expect(progress.isWalkingBackward)
        progress.declineReverse()
        #expect(!progress.isWalkingBackward && progress.reversedAlong == nil)
    }

    @Test("A short loop walked the other way turns round instead of counting its checkpoints")
    func shortLoopWalkedBackward() throws {
        let a = at(east: 0, north: 0)
        var progress = try loopProgress([a, at(east: 60, north: 0), at(east: 60, north: 60), at(east: 0, north: 60), a])
        let count = progress.checkpointAlong.count
        for north in stride(from: 0.0, through: 60, by: 5) {
            _ = progress.update(location: at(east: 0, north: north), at: Date(), alertsEnabled: true)
            #expect(progress.checkpointsToAdvance(from: 1, waypointCount: count) == 0, "at \(north) m")
            if progress.isWalkingBackward { break }
        }
        #expect(progress.isWalkingBackward)
    }

    // MARK: Alert timing (2026-09-25 review of #65)

    @Test("Poor-accuracy fixes drifting past 50 m do not raise the alert; accurate ones do")
    func lowAccuracyDoesNotAlert() throws {
        let path = straight
        let start = Date()
        var fuzzy = try #require(TrailProgress(route: route(path: path, waypoints: [path[0], path[10]], loop: false)))
        var clear = fuzzy
        for second in stride(from: 0.0, through: 30, by: 5) {
            #expect(fuzzy.update(location: at(east: 300, north: 60), accuracy: 40, at: start + second,
                                 alertsEnabled: true) == nil, "at \(second) s")
        }
        #expect(!fuzzy.isOffTrail)
        var event: OffTrailMonitor.Event?
        for second in stride(from: 0.0, through: 30, by: 5) where event == nil {
            event = clear.update(location: at(east: 300, north: 60), accuracy: 5, at: start + second, alertsEnabled: true)
        }
        #expect(event == .left, "60 m off, known to within 5 m")
    }

    @Test("A pause starts the off-trail clock over")
    func pauseResetsClock() throws {
        let path = straight
        var progress = try #require(TrailProgress(route: route(path: path, waypoints: [path[0], path[10]], loop: false)))
        let start = Date()
        _ = progress.update(location: at(east: 300, north: 55), at: start, alertsEnabled: true)
        #expect(progress.tick(at: start + 10, alertsEnabled: true) == nil)
        progress.resetOffTrail()   // paused, walked back, resumed a minute later
        #expect(progress.tick(at: start + 70, alertsEnabled: true) == nil, "10 s off before the pause is not 70 s off")
        #expect(progress.tick(at: start + 95, alertsEnabled: true) == nil,
                "no fix since resuming: the distance from before the pause is forgotten, not reused")
    }

    @Test("Switching alerts off clears the banner on the next tick, without a new fix")
    func alertsOffClearsBanner() throws {
        let path = straight
        var progress = try #require(TrailProgress(route: route(path: path, waypoints: [path[0], path[10]], loop: false)))
        let start = Date()
        _ = progress.update(location: at(east: 300, north: 130), at: start, alertsEnabled: true)
        #expect(progress.tick(at: start + 21, alertsEnabled: true) == .left)
        #expect(progress.isOffTrail)
        _ = progress.tick(at: start + 22, alertsEnabled: false)
        #expect(!progress.isOffTrail)
    }

    @Test("The arrow turns the short way, across north too")
    func arrowTurnsShortWay() {
        // Facing 355° → 5° with the trail at 90°: -265° → 85° is a 350° spin.
        #expect(ArrowTurn.angle(from: -265, to: 85) == -275)
        #expect(ArrowTurn.angle(from: 170, to: -170) == 190)
        #expect(ArrowTurn.angle(from: 0, to: 90) == 90)
        #expect(ArrowTurn.angle(from: 720, to: 10) == 730)
    }

    // MARK: Where a walk starts, and jumps (2026-09-25 review of #65/#66)

    /// 400 m square loop: a → b → c → d → a, 1.6 km.
    private var squareLoop: [CLLocationCoordinate2D] {
        let a = at(east: 0, north: 0)
        return [a, at(east: 400, north: 0), at(east: 400, north: 400), at(east: 0, north: 400), a]
    }

    private func loopProgress(_ path: [CLLocationCoordinate2D]) throws -> TrailProgress {
        let length = TrailWalkPlanner.length(path)
        let waypoints = TrailWalkPlanner.checkpoints(along: path, isLoop: true, length: length)
        return try #require(TrailProgress(route: route(path: path, waypoints: waypoints, loop: true)))
    }

    @Test("Starting a loop beside where it closes starts at the start, not the finish")
    func loopStartIsNotTheFinish() throws {
        var progress = try loopProgress(squareLoop)
        // 10 m west, 5 m north of the start: nearer the loop's last stretch
        // (10 m) than its first (11 m). This used to finish the walk.
        _ = progress.update(location: at(east: -10, north: 5), at: Date(), alertsEnabled: true)
        #expect((progress.along ?? .infinity) < 20, "along \(progress.along ?? -1)")
        #expect(!progress.hasReached(waypoint: 1))
        #expect(!progress.hasReached(waypoint: 0), "the finish")
        #expect(progress.checkpointsToAdvance(from: 1, waypointCount: progress.checkpointAlong.count) == 0)
    }

    @Test("A loop shorter than the look-ahead: GPS noise at the start does not pick the finish")
    func shortLoopStart() throws {
        // 60 m square, 240 m round: both ends inside the window.
        let a = at(east: 0, north: 0)
        var progress = try loopProgress([a, at(east: 60, north: 0), at(east: 60, north: 60), at(east: 0, north: 60), a])
        for point in [at(east: -3, north: 2), at(east: -2, north: 4), at(east: -4, north: 1)] {
            _ = progress.update(location: point, at: Date(), alertsEnabled: true)
            #expect((progress.along ?? .infinity) < 20, "along \(progress.along ?? -1)")
        }
        #expect(progress.checkpointsToAdvance(from: 1, waypointCount: progress.checkpointAlong.count) == 0)
    }

    @Test("After a gap in fixes, an out-and-back keeps to the way out")
    func outAndBackGap() throws {
        // 1.5 km out, and back 6 m to the north (a path's two sides).
        let path = (0...15).map { at(east: Double($0) * 100, north: 0) }
            + (0...15).reversed().map { at(east: Double($0) * 100, north: 6) }
        let length = TrailWalkPlanner.length(path)
        let waypoints = TrailWalkPlanner.checkpoints(along: path, isLoop: false, length: length)
        var progress = try #require(TrailProgress(route: route(path: path, waypoints: waypoints, loop: false)))
        for east in stride(from: 0.0, through: 600, by: 100) {
            _ = progress.update(location: at(east: east, north: 0), at: Date(), alertsEnabled: true)
        }
        // No fix for 350 m, then one nearer the way back (1.5 m) than the way out (4.5 m).
        _ = progress.update(location: at(east: 950, north: 4.5), at: Date(), alertsEnabled: true)
        #expect(abs((progress.along ?? 0) - 950) < 5, "along \(progress.along ?? -1)")
    }

    @Test("A clearly nearer stretch counts only once several fixes agree")
    func jumpNeedsAgreement() throws {
        var progress = try #require(TrailProgress(route: route(path: hairpin, waypoints: [hairpin[0], hairpin[11]], loop: false)))
        _ = progress.update(location: at(east: 100, north: 0), at: Date(), alertsEnabled: true)
        _ = progress.update(location: at(east: 150, north: 0), at: Date(), alertsEnabled: true)
        // Onto the way back (40 m north), which is 350 m further along.
        _ = progress.update(location: at(east: 150, north: 40), at: Date(), alertsEnabled: true)
        #expect(abs((progress.along ?? 0) - 150) < 3, "one fix is not enough")
        _ = progress.update(location: at(east: 145, north: 40), at: Date(), alertsEnabled: true)
        _ = progress.update(location: at(east: 140, north: 40), at: Date(), alertsEnabled: true)
        // The way back reaches x = 140 after 500 + 40 + 360 m.
        #expect(abs((progress.along ?? 0) - 900) < 3, "three agreeing fixes are a shortcut taken")
    }

    @Test("Setting off round a loop the other way turns the route round instead of counting its checkpoints")
    func loopWalkedBackward() throws {
        var progress = try loopProgress(squareLoop)
        let count = progress.checkpointAlong.count
        // Up the loop's last stretch from the start, 5 m a fix.
        for north in stride(from: 0.0, through: 60, by: 5) {
            _ = progress.update(location: at(east: 0, north: north), at: Date(), alertsEnabled: true)
            #expect(progress.checkpointsToAdvance(from: 1, waypointCount: count) == 0, "at \(north) m")
            #expect(!progress.hasReached(waypoint: 0))
            if progress.isWalkingBackward { break }
        }
        #expect(progress.isWalkingBackward)
        let reversedAlong = try #require(progress.reversedAlong)
        #expect(reversedAlong > 20 && reversedAlong < 60, "reversedAlong \(reversedAlong)")

        // The session then follows the reversed route from there.
        let loop = route(path: squareLoop, waypoints: TrailWalkPlanner.checkpoints(along: squareLoop, isLoop: true,
                                                                                    length: 1600), loop: true)
        let turned = try #require(loop.reversedAlongLine())
        #expect(turned.path?.count == 5 && turned.isLoop)
        #expect(TrailWalkPlanner.meters(turned.waypoints[0], squareLoop[0]) < 1, "same start")
        // Checkpoints every 533 m from the start, now up the west side and along the top.
        #expect(TrailWalkPlanner.meters(turned.waypoints[1], at(east: 133, north: 400)) < 5,
                "first checkpoint is now round the other way")
        var onward = try #require(TrailProgress(route: turned))
        onward.resume(at: reversedAlong)
        _ = onward.update(location: at(east: 0, north: 80), at: Date(), alertsEnabled: true)
        #expect(abs((onward.along ?? 0) - 80) < 3)
    }

    @Test("Several checkpoints can pass on one fix, but never the finish with them")
    func finishNeedsItsOwnFix() throws {
        let path = straight
        var line = try #require(TrailProgress(route: route(path: path, waypoints: [path[0], path[5], path[10]], loop: false)))
        line.resume(at: 1000)
        #expect(line.checkpointsToAdvance(from: 1, waypointCount: 3) == 1, "checkpoint 1, not the finish")
        #expect(line.checkpointsToAdvance(from: 2, waypointCount: 3) == 1, "the finish, on the next fix")

        var loop = try loopProgress(squareLoop)
        let count = loop.checkpointAlong.count
        loop.resume(at: 1600)
        #expect(loop.checkpointsToAdvance(from: 1, waypointCount: count) == count - 1, "every checkpoint but the finish")
        #expect(loop.checkpointsToAdvance(from: 0, waypointCount: count) == 1, "then the finish")
    }

    @Test("A walk's position along the line survives a crash snapshot; older snapshots have none")
    func snapshotKeepsTrailPosition() throws {
        let route = route(path: straight, waypoints: [straight[0], straight[10]], loop: false)
        let snapshot = ActiveWalkSnapshot(route: .init(route), startTime: Date(), totalDistanceCovered: 750,
                                          pausedDuration: 0, isPaused: false, pauseStartDate: nil,
                                          currentWaypointIndex: 1, currentLap: 1, triggeredCheckpoints: [],
                                          splitTimes: [], liveSteps: 0, checkpointDate: Date(), trailAlong: 740)
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(ActiveWalkSnapshot.self, from: data).trailAlong == 740)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "trailAlong")
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(ActiveWalkSnapshot.self, from: old).trailAlong == nil)
    }

    // MARK: Words

    @Test("Compass words for bearings, including the wrap at north")
    func compassWords() {
        #expect(CompassDirection.name(for: 0) == "north")
        #expect(CompassDirection.name(for: 350) == "north")
        #expect(CompassDirection.name(for: 44) == "northeast")
        #expect(CompassDirection.name(for: 90) == "east")
        #expect(CompassDirection.name(for: 200) == "south")
        #expect(CompassDirection.name(for: -90) == "west")
        #expect(CompassDirection.name(for: 315) == "northwest")
    }
}
