import CoreLocation
import Foundation

// MARK: - Guiding a trail walk
//
// Where the person is relative to the trail they are walking: how far along
// it, how far off it, and which way it lies (Joe, 2026-09-24: off-trail
// alerts and direction help). Everything here is pure and works offline from
// the trail's own line on `NavigableRoute.path`.
//
// Progress is measured ALONG the trail, not in straight lines. A straight
// line to the next checkpoint lies about a winding trail, and a checkpoint
// that had to be passed within 60 m could be missed where trail data sits off
// the ground path, stalling the session. Now a checkpoint counts once the
// person's position along the trail has passed it.

/// A trail's line with distances along it.
struct TrailGuide {
    let path: [CLLocationCoordinate2D]
    /// Distance along the line at each vertex; the last is the line's length.
    let cumulative: [Double]

    var length: Double { cumulative.last ?? 0 }

    init(path: [CLLocationCoordinate2D]) {
        self.path = path
        var running = 0.0
        var cumulative = [0.0]
        for (a, b) in zip(path, path.dropFirst()) {
            running += TrailWalkPlanner.meters(a, b)
            cumulative.append(running)
        }
        self.cumulative = cumulative
    }

    struct Position: Equatable {
        /// Metres along the line to the nearest point on it.
        let along: Double
        /// Metres from the person to that point.
        let offset: Double
        /// The nearest point on the line.
        let nearest: CLLocationCoordinate2D

        static func == (a: Position, b: Position) -> Bool {
            a.along == b.along && a.offset == b.offset
                && a.nearest.latitude == b.nearest.latitude && a.nearest.longitude == b.nearest.longitude
        }
    }

    /// The point `along` metres along the line, clamped to its ends.
    func point(atAlong along: Double) -> CLLocationCoordinate2D {
        guard let first = path.first else { return CLLocationCoordinate2D() }
        let s = min(max(0, along), length)
        for i in 0..<(path.count - 1) where cumulative[i + 1] >= s {
            let segment = cumulative[i + 1] - cumulative[i]
            let t = segment > 0 ? (s - cumulative[i]) / segment : 0
            let a = path[i], b = path[i + 1]
            return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                          longitude: a.longitude + (b.longitude - a.longitude) * t)
        }
        return path.last ?? first
    }

    /// Distance along the line of the point on it nearest `point`, looking
    /// only at or after `minimum`. Nearest wins outright; on an exact tie the
    /// earlier point does.
    func nearestAlong(to point: CLLocationCoordinate2D, atOrAfter minimum: Double) -> Double {
        guard path.count >= 2 else { return 0 }
        var best: Position?
        for i in 0..<(path.count - 1) where cumulative[i + 1] >= minimum {
            let candidate = project(point, onSegment: i)
            guard candidate.along >= minimum - 0.01 else { continue }
            if best == nil || candidate.offset < best?.offset ?? .infinity { best = candidate }
        }
        return best?.along ?? minimum
    }

    /// The nearest point anywhere on the line.
    func position(of point: CLLocationCoordinate2D) -> Position? {
        guard path.count >= 2 else { return nil }
        return (0..<(path.count - 1)).map { project(point, onSegment: $0) }.min { $0.offset < $1.offset }
    }

    /// One point per stretch of the line near `point`: where the distance to
    /// the line is at a local minimum as you go along it, within `within`
    /// metres of the nearest. A line recorded every 5 m has dozens of
    /// segments beside the person, and treating each as a separate place to
    /// be was how a backward walk crept forward along a loop's first stretch
    /// (2026-09-25 review of #69). Two stretches — an out-and-back's two
    /// sides, a loop's start and finish — stay two candidates.
    func stretches(near point: CLLocationCoordinate2D, within: Double = 60) -> (candidates: [Position], nearest: Position)? {
        guard path.count >= 2 else { return nil }
        let projections = (0..<(path.count - 1)).map { project(point, onSegment: $0) }
        guard let nearest = projections.min(by: { $0.offset < $1.offset }) else { return nil }
        var result: [Position] = []
        for (i, p) in projections.enumerated() where p.offset <= nearest.offset + within {
            let before = i > 0 ? projections[i - 1] : nil
            let after = i < projections.count - 1 ? projections[i + 1] : nil
            guard p.offset <= (before?.offset ?? .infinity) + 1e-6,
                  p.offset <= (after?.offset ?? .infinity) + 1e-6 else { continue }
            // Two segments meeting at the same nearest vertex are one place.
            if let before, abs(before.offset - p.offset) < 1e-6, abs(before.along - p.along) < 1e-3 { continue }
            result.append(p)
        }
        return (result, nearest)
    }

    /// Nearest point on segment `i`, in a local flat projection (plenty at trail scale).
    private func project(_ p: CLLocationCoordinate2D, onSegment i: Int) -> Position {
        let a = path[i], b = path[i + 1]
        let metersPerDegree = 111_320.0
        let cosLat = max(0.01, cos(p.latitude * .pi / 180))
        func xy(_ c: CLLocationCoordinate2D) -> (Double, Double) {
            ((c.longitude - p.longitude) * metersPerDegree * cosLat, (c.latitude - p.latitude) * metersPerDegree)
        }
        let (ax, ay) = xy(a), (bx, by) = xy(b)
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? max(0, min(1, -(ax * dx + ay * dy) / lengthSquared)) : 0
        let nx = ax + t * dx, ny = ay + t * dy
        let nearest = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                             longitude: a.longitude + (b.longitude - a.longitude) * t)
        let segmentLength = cumulative[i + 1] - cumulative[i]
        return Position(along: cumulative[i] + t * segmentLength,
                        offset: (nx * nx + ny * ny).squareRoot(),
                        nearest: nearest)
    }
}

// MARK: - Off-trail alerts

/// Decides when someone has left the trail and when they are back, with
/// enough patience that GPS wobble and a step aside to let someone pass never
/// trigger it. The thresholds are generous because trail data itself can sit
/// tens of metres from the path on the ground (2026-09-24).
struct OffTrailMonitor {
    /// Farther than this from the trail...
    static let leaveMeters = 50.0
    /// ...for this long, and they have left it.
    static let leaveSeconds = 20.0
    /// Back within this distance (less than `leaveMeters`, so hovering at the
    /// edge does not flicker between the two)...
    static let returnMeters = 30.0
    /// ...for this long, and they are back.
    static let returnSeconds = 5.0

    enum Event: Equatable { case left, returned }

    private(set) var isOffTrail = false
    private var overSince: Date?
    private var underSince: Date?

    mutating func update(offset: Double, at now: Date) -> Event? {
        if !isOffTrail {
            guard offset > Self.leaveMeters else { overSince = nil; return nil }
            let since = overSince ?? now
            overSince = since
            guard now.timeIntervalSince(since) >= Self.leaveSeconds else { return nil }
            isOffTrail = true
            underSince = nil
            return .left
        } else {
            guard offset < Self.returnMeters else { underSince = nil; return nil }
            let since = underSince ?? now
            underSince = since
            guard now.timeIntervalSince(since) >= Self.returnSeconds else { return nil }
            isOffTrail = false
            overSince = nil
            return .returned
        }
    }

    mutating func reset() {
        isOffTrail = false
        overSince = nil
        underSince = nil
    }
}

// MARK: - Progress along a trail walk

/// The session's view of a trail walk: position along the line, checkpoints
/// as distances along it, and the off-trail state.
///
/// Position is tracked as a sequence, not fix by fix (rebuilt 2026-09-25).
/// Three rounds of per-fix rules (#67–#69) each fixed one shape and broke
/// another: a loop's start read as its finish, an out-and-back's way home
/// counted backwards, a backward walk crept forward along a densely recorded
/// line. Now several guesses of where the person is stay alive at once. Each
/// fix scores every guess by how far the fix is from the line there and by
/// whether getting there means travelling along the line about as far as the
/// person actually moved — going backwards costs extra. The cheapest guess
/// is the answer, and a guess that loses one fix can win the next, so a gap
/// at a turnaround or a restore on the way home recovers within a few fixes.
///
/// Progress is distance walked along the line (`Guess.walked`), not where on
/// the line the person is: on a loop or a recording that came home, being
/// beside the finish is not having walked to it.
struct TrailProgress {
    let guide: TrailGuide
    /// Distance along the line of each of the route's waypoints (checkpoints).
    let checkpointAlong: [Double]
    let isLoop: Bool
    /// The line ends where it starts: a loop, or a recording that came home.
    /// Only such a line can be walked the other way from its start.
    let isClosed: Bool

    /// Distance walked along the line, 0...length; nil before the first fix
    /// on the trail.
    private(set) var along: Double?
    private(set) var offset: Double?
    /// The distance the off-trail clock judges by: `offset`, less the fix's
    /// uncertainty while the person is still on the trail. Under tree cover a
    /// fix can be 40 m out, and 20 s of those drifting past 50 m raised the
    /// alert on someone standing on the trail (2026-09-25 review).
    private var alertOffset: Double?
    private(set) var nearest: CLLocationCoordinate2D?
    private(set) var monitor = OffTrailMonitor()
    /// The person is walking a closed line the other way round. The session
    /// turns the route round (`NavigableRoute.reversedAlongLine`) and starts a
    /// new progress at `reversedAlong`.
    private(set) var isWalkingBackward = false
    /// Where the person is on the reversed line, once `isWalkingBackward`.
    private(set) var reversedAlong: Double?

    /// One guess at where the person is.
    private struct Guess {
        /// Where on the line.
        var at: Double
        /// Distance walked along the line to get there, signed: a backward
        /// start on a closed line goes negative.
        var walked: Double
        /// `walked` where this guess's walk began: its first fix, or the
        /// position resumed at. Each guess keeps its own — taken over all
        /// guesses, one far-fetched first guess 800 m round the loop delayed
        /// turning round by 800 m (2026-09-25 review of the rebuild).
        var began: Double?
        /// Accumulated cost; lower is likelier.
        var cost: Double
    }
    private var guesses: [Guess]
    /// Where and when the last fix that counted was (the planned start, at no
    /// time, before any).
    private var lastFix: CLLocationCoordinate2D
    private var lastFixTime: Date?
    /// Consecutive fixes on which the likeliest guess was behind the start.
    /// One fix can be a leap — after a restore, a single fix 36 m away on a
    /// small loop reads as well backwards as forwards — so turning round
    /// waits for a second (2026-09-25 review of the rebuild).
    private var fixesBehind = 0
    static let fixesBehindToTurn = 2

    /// A checkpoint counts this far before its exact position, so the last
    /// few metres of GPS noise never hold a session up.
    static let reachSlack = 20.0
    /// Start and end this close make a closed line.
    static let closedMeters = 30.0
    /// GPS error assumed for a fix, at least (metres).
    static let fixSigma = 8.0
    /// Metres of mismatch between distance along the line and distance
    /// moved that cost one unit.
    static let travelScale = 10.0
    /// Extra cost of a step backwards along the line, and more per metre: a
    /// long way back is less likely than a long way on. After a gap of more
    /// than half a loop, the shorter way round is backwards, and without the
    /// per-metre cost the walk turned round and restarted its checkpoints.
    /// Without the flat cost, walking home along the outbound side of a
    /// recorded out-and-back 12–15 m from the return line read as walking
    /// backwards (2026-09-25 reviews of the rebuild).
    static let backwardCost = 2.0
    static let backwardCostPerMeter = 0.18
    /// The long way round a closed line is only considered when the time since
    /// the last fix that counted could cover it at this speed, plus
    /// `longWayMargin`. Scored unconditionally, a walk's first fixes near
    /// another stretch of a small loop were credited with most of the loop:
    /// "Walk complete" after 65 m of 344 (2026-09-25 review of the rebuild).
    let longWaySpeed: Double
    static let longWayMargin = 40.0
    /// Guesses kept, and how much costlier than the best one may be.
    static let maxGuesses = 10
    static let keepWithin = 100.0
    /// This far behind the start of a closed line — and behind where the walk
    /// began, if that was behind it (the planner starts a trail at its nearest
    /// data point, which can be 50 m or more from the person) — the person is
    /// going round the other way. It depends only on where the likeliest guess is now, never on
    /// where a guess has been: the first version also required never having
    /// gone 15 m forwards, and a change of mind, or a start a few metres past
    /// the planned start, left progress at 0 for the rest of the walk (138 of
    /// 1,035 backward walks on real loops; 2026-09-25 review of the rebuild).
    static let backwardTrigger = 25.0

    init?(route: NavigableRoute) {
        guard let path = route.path, path.count >= 2 else { return nil }
        let guide = TrailGuide(path: path)
        // Checkpoints are points on the line (TrailWalkPlanner.checkpoints),
        // so each is placed at its exact nearest point at or after the one
        // before (2026-09-25 review of #69).
        var previous = 0.0
        checkpointAlong = route.waypoints.map { waypoint in
            let along = guide.nearestAlong(to: waypoint, atOrAfter: previous)
            previous = along
            return along
        }
        self.guide = guide
        isLoop = route.isLoop
        isClosed = path.count > 2 && TrailWalkPlanner.meters(path[0], path[path.count - 1]) <= Self.closedMeters
        longWaySpeed = route.activityMode.drivingSpeedCeiling
        // The walk starts at the start of the line: the planner begins a trail
        // walk where the person is, and a recording begins where it began.
        guesses = [Guess(at: 0, walked: 0, began: nil, cost: 0)]
        lastFix = path[0]
    }

    /// Picks up from a known distance walked: a restored session (`since` is
    /// when it was saved — the person may have walked on meanwhile), or a
    /// route just turned round (`since` is the fix it turned on).
    mutating func resume(at along: Double, since: Date? = nil) {
        let at = min(max(0, along), guide.length)
        self.along = at
        guesses = [Guess(at: at, walked: at, began: at, cost: 0)]
        lastFix = guide.point(atAlong: at)
        lastFixTime = since
        fixesBehind = 0
    }

    var isOffTrail: Bool { monitor.isOffTrail }

    /// Metres of trail left to walk.
    var remaining: Double { max(0, guide.length - (along ?? 0)) }

    /// Where waypoint `index` sits along the line. On a loop, index 0 is both
    /// the start and the finish; as a target it is the finish.
    func targetAlong(forWaypoint index: Int) -> Double {
        if isLoop, index == 0 { return guide.length }
        return checkpointAlong.indices.contains(index) ? checkpointAlong[index] : guide.length
    }

    func distanceAlong(toWaypoint index: Int) -> Double {
        max(0, targetAlong(forWaypoint: index) - (along ?? 0))
    }

    func hasReached(waypoint index: Int) -> Bool {
        guard let along else { return false }
        return along >= targetAlong(forWaypoint: index) - Self.reachSlack
    }

    /// How many checkpoints the session passes now, starting from
    /// `currentIndex` (NavigationSessionManager's `currentWaypointIndex`).
    /// Several can pass together after a gap, but never the finish together
    /// with another: the finish needs the checkpoint before it reached on an
    /// earlier fix, so no single fix can take a walk from the start to "Walk
    /// complete".
    func checkpointsToAdvance(from currentIndex: Int, waypointCount count: Int) -> Int {
        guard count > 0 else { return 0 }
        var index = currentIndex
        var passed = 0
        for _ in 0...count {
            let target = isLoop ? index % count : index
            guard target < count, hasReached(waypoint: target) else { break }
            let isFinish = isLoop ? target == 0 : target == count - 1
            if isFinish, passed > 0 { break }
            passed += 1
            if isFinish { break }
            index += 1
            if isLoop, index >= count { index = 0 }
        }
        return passed
    }

    /// Feeds one location fix, with its horizontal accuracy in metres. Returns
    /// an off-trail event when one happens and alerts are on; position and
    /// progress update either way.
    mutating func update(location: CLLocationCoordinate2D, accuracy: Double = 0, at now: Date,
                         alertsEnabled: Bool) -> OffTrailMonitor.Event? {
        guard let found = guide.stretches(near: location) else { return nil }
        offset = found.nearest.offset
        nearest = found.nearest.nearest
        // Leaving has to be beyond doubt; coming back is judged as measured.
        alertOffset = monitor.isOffTrail ? found.nearest.offset : max(0, found.nearest.offset - max(0, accuracy))
        // Progress only moves while the person is on the trail. Off it, the
        // next fix back on it is judged from the last one that counted, so a
        // detour that rejoins further on is travel, not a leap.
        if found.nearest.offset <= OffTrailMonitor.leaveMeters {
            track(to: found.candidates, at: location, time: now, accuracy: accuracy)
        }
        guard alertsEnabled else {
            monitor.reset()
            return nil
        }
        return monitor.update(offset: alertOffset ?? found.nearest.offset, at: now)
    }

    /// Moves every guess on to each candidate stretch and keeps the likeliest.
    private mutating func track(to candidates: [TrailGuide.Position], at location: CLLocationCoordinate2D,
                                time: Date, accuracy: Double) {
        let moved = TrailWalkPlanner.meters(lastFix, location)
        let reach = Self.longWayMargin + longWaySpeed * max(0, time.timeIntervalSince(lastFixTime ?? time))
        let sigma = max(Self.fixSigma, accuracy)
        var next: [Guess] = []
        for candidate in candidates {
            let fit = candidate.offset * candidate.offset / (2 * sigma * sigma)
            var best: Guess?
            for guess in guesses {
                for step in steps(from: guess.at, to: candidate.along, within: reach) {
                    let travel = abs(abs(step) - moved) / Self.travelScale
                        + (step < 0 ? Self.backwardCost - step * Self.backwardCostPerMeter : 0)
                    let cost = guess.cost + travel + fit
                    if best == nil || cost < best?.cost ?? .infinity {
                        let walked = guess.walked + step
                        best = Guess(at: candidate.along, walked: walked, began: guess.began ?? walked, cost: cost)
                    }
                }
            }
            if let best { next.append(best) }
        }
        next.sort { $0.cost < $1.cost }
        guard let leader = next.first else { return }
        guesses = next.prefix(Self.maxGuesses)
            .filter { $0.cost <= leader.cost + Self.keepWithin }
            .map { var g = $0; g.cost -= leader.cost; return g }
        lastFix = location
        lastFixTime = time
        along = min(max(0, leader.walked), guide.length)
        // Judged on the likeliest guess's own origin: where a loop's first and
        // last stretches run side by side (Rob Wallace Park), the first fix
        // can't tell 4 m past the start from 53 m before it, and once the
        // truth leads, its own origin is 53 m back (2026-09-25).
        let behind = isClosed && leader.walked <= min(leader.began ?? leader.walked, 0) - Self.backwardTrigger
        fixesBehind = behind ? fixesBehind + 1 : 0
        if fixesBehind >= Self.fixesBehindToTurn {
            isWalkingBackward = true
            // On the line walked the other way, they are as far past its
            // start as they are behind this one's.
            reversedAlong = -leader.walked
        }
    }

    /// The ways to travel along the line from `a` to `b`. On a closed line
    /// both ways round the join: from just past the start, the far side of
    /// the join is a few metres back; after a long gap it is most of the
    /// line ahead. The longer is scored too when there has been time to walk
    /// it (`reach`); the shorter always is.
    private func steps(from a: Double, to b: Double, within reach: Double) -> [Double] {
        guard isClosed, guide.length > 0 else { return [b - a] }
        var forward = (b - a).truncatingRemainder(dividingBy: guide.length)
        if forward < 0 { forward += guide.length }
        let back = forward - guide.length
        let (shorter, longer) = forward <= -back ? (forward, back) : (back, forward)
        return abs(longer) <= reach ? [shorter, longer] : [shorter]
    }

    /// Starts the off-trail clock over. The session calls it on pause and
    /// resume: time paused is not time spent off the trail, and the last
    /// distance from before a pause says nothing about where the person is
    /// after it — they got a false "You've left" on the first tick after
    /// resuming (2026-09-25 review).
    mutating func resetOffTrail() {
        monitor.reset()
        offset = nil
        alertOffset = nil
    }
}

extension TrailProgress {
    /// The clock's turn. Someone who wanders off and then stands still gets
    /// no new location fixes (the session asks for one every 5 m moved), so
    /// the monitor also advances on the session's one-second timer, with the
    /// last known distance from the trail. Without this, the person most
    /// likely to be lost — stopped, unsure which way to go — was never alerted
    /// (found on the simulator, 2026-09-24).
    mutating func tick(at now: Date, alertsEnabled: Bool) -> OffTrailMonitor.Event? {
        // Switched off, the banner goes on the next tick rather than waiting
        // for the person to move 5 m and produce a fix.
        guard alertsEnabled else {
            monitor.reset()
            return nil
        }
        guard let offset = alertOffset ?? offset else { return nil }
        return monitor.update(offset: offset, at: now)
    }
}

// MARK: - The session's steps, shared with its tests

/// Where a guided session goes when it reaches its current waypoint.
/// `NavigationSessionManager.advanceWaypoint` applies it and adds the
/// splits and notifications; the tests walk whole routes through it, so the
/// state they check is the state the app keeps.
struct WaypointStep: Equatable {
    var index: Int
    var lap: Int
    var finished: Bool

    /// The split and notification label on a custom route for arriving at
    /// waypoint `index`: "WP 5/5" for a loop's last, not the wrapped "WP 0/5"
    /// (2026-09-25 review of the rebuild).
    static func label(arrivingAt index: Int, count: Int) -> String {
        "WP \(min(index + 1, count))/\(count)"
    }

    static func after(index: Int, lap: Int, count: Int, isLoop: Bool, lapCount: Int) -> WaypointStep {
        let next = index + 1
        if isLoop {
            if next >= count { return WaypointStep(index: 0, lap: lap, finished: false) }
            if next == 1 { return WaypointStep(index: 1, lap: lap + 1, finished: lap + 1 > lapCount) }
            return WaypointStep(index: next, lap: lap, finished: false)
        }
        return WaypointStep(index: next, lap: lap, finished: next >= count)
    }
}

extension TrailProgress {
    /// A walk turned round because the person is going round a closed line
    /// the other way: the reversed route, progress resumed where they are on
    /// it, and the walk starting over at waypoint 1, lap 1 — they are back
    /// behind the start, even if they passed checkpoint 1 on the way out.
    struct TurnedRound {
        let route: NavigableRoute
        let progress: TrailProgress
        let index: Int
        let lap: Int
    }

    func turnedRound(_ route: NavigableRoute) -> TurnedRound? {
        guard isWalkingBackward, let reversed = route.reversedAlongLine(),
              var progress = TrailProgress(route: reversed) else { return nil }
        progress.resume(at: reversedAlong ?? 0, since: lastFixTime)
        return TurnedRound(route: reversed, progress: progress, index: 1, lap: 1)
    }
}

// MARK: - Directions in words

/// Turning the off-trail arrow. `rotationEffect` animates the number it is
/// given, so going from facing 355° to 5° with the trail at 90° (-265° to 85°)
/// spun the arrow 350° the long way round, just as a lost person was reading it.
enum ArrowTurn {
    /// The angle equal to `target` (mod 360) that is nearest `current`, so the
    /// arrow always turns the short way.
    static func angle(from current: Double, to target: Double) -> Double {
        var delta = (target - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return current + delta
    }
}

enum CompassDirection {
    /// "north", "northeast"… for a bearing in degrees clockwise from north.
    static func name(for bearing: Double) -> String {
        let names = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        let normalized = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((normalized + 22.5) / 45) % 8]
    }
}
