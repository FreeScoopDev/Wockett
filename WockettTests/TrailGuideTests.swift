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
