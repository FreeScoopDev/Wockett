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

    /// How far back and ahead of the last known position to look first.
    /// Narrow on purpose: a wider window takes in the far side of a trail
    /// that doubles back on itself, which is exactly the jump it exists to
    /// prevent. After a gap in fixes the session widens the look-ahead by how
    /// far the person could have gone meanwhile (`TrailProgress`), so a gap
    /// does not hand the choice to whichever stretch happens to be nearest.
    static let windowBehind = 100.0
    static let windowAhead = 250.0
    /// How much closer another part of the trail must be to win over the part
    /// the person has been following.
    static let switchMargin = 25.0
    /// Inside the window, points this close to the nearest count as equally
    /// near, and the one nearest where the person is expected to be along the
    /// line wins. On a loop shorter than the window both ends are in it, and
    /// GPS noise alone must not decide between the start and the finish; on
    /// an out-and-back both sides of the street are, and the way home must
    /// win once they are past the turn.
    static let tieMeters = 15.0

    /// The nearest point anywhere on the line, and the point within the window
    /// around `previousAlong` (nil without one, or when no stretch falls inside
    /// it): the nearest, or among points about as near, the one closest along
    /// the line to `expectedAlong` — the previous position plus the distance
    /// moved since. The previous position alone was the first version
    /// (#67), and on an out-and-back it always chose the way-out side just
    /// behind the person, so coming home counted backwards and the walk never
    /// finished (2026-09-25 review of #67/#68).
    struct Candidates {
        let best: Position
        let inWindow: Position?

        /// The window's point unless another stretch is clearly closer.
        var preferred: Position {
            if let inWindow, inWindow.offset <= best.offset + TrailGuide.switchMargin { return inWindow }
            return best
        }
    }

    func candidates(for point: CLLocationCoordinate2D, near previousAlong: Double?,
                    expectedAlong: Double? = nil, ahead: Double = Self.windowAhead) -> Candidates? {
        guard path.count >= 2 else { return nil }
        var best: Position?
        var inWindow: [Position] = []
        let lo = (previousAlong ?? 0) - Self.windowBehind
        let hi = (previousAlong ?? 0) + ahead
        for i in 0..<(path.count - 1) {
            let candidate = project(point, onSegment: i)
            if best == nil || candidate.offset < best?.offset ?? .infinity { best = candidate }
            if previousAlong != nil, cumulative[i + 1] >= lo, cumulative[i] <= hi {
                inWindow.append(candidate)
            }
        }
        guard let best else { return nil }
        let nearestInWindow = inWindow.map(\.offset).min() ?? .infinity
        let expected = expectedAlong ?? previousAlong ?? 0
        let chosen = inWindow
            .filter { $0.offset <= nearestInWindow + Self.tieMeters }
            .min { abs($0.along - expected) < abs($1.along - expected) }
        return Candidates(best: best, inWindow: chosen)
    }

    /// The person's position on the line. With `previousAlong`, the stretch
    /// near where they were is preferred, so a trail that doubles back beside
    /// itself does not make progress jump to its other side; a part of the
    /// trail that is clearly closer still wins (a shortcut, or a wrong start).
    func position(of point: CLLocationCoordinate2D, near previousAlong: Double? = nil) -> Position? {
        candidates(for: point, near: previousAlong)?.preferred
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
/// Position only moves by being walked (2026-09-25 review of #65/#66). It
/// starts at the start of the line and follows on from the last position; a
/// fix that lands on some other stretch counts only after several fixes agree.
/// Before this, the first fix took the nearest point anywhere, and on a loop —
/// or a recording that ends at the door it began at — the start is also the
/// finish: about a third of starts landed on the finish and ended the walk on
/// the spot.
struct TrailProgress {
    let guide: TrailGuide
    /// Distance along the line of each of the route's waypoints (checkpoints).
    let checkpointAlong: [Double]
    let isLoop: Bool
    /// The line ends where it starts: a loop, or a recording that came home.
    /// Only such a line can be walked the other way from its start.
    let isClosed: Bool

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

    /// Where the last counted position was taken. The look-ahead widens by how
    /// far the person has moved from it — not by time, which would let someone
    /// standing at the start of a loop for five minutes reach its finish.
    private var lastAcceptedLocation: CLLocationCoordinate2D?
    /// A position on another stretch, waiting for more fixes to agree.
    private var pendingJump: (along: Double, count: Int, location: CLLocationCoordinate2D)?
    /// Metres along a trail per metre in a straight line, generously: how far
    /// along the line a gap in fixes can have taken someone.
    static let windingFactor = 2.0
    /// A step forward along the line beyond `windingFactor` × the distance
    /// moved, plus this, is a leap nobody walked, and needs the same
    /// agreement as a jump to another stretch. On a loop shorter than the
    /// window, its closing stretch is inside the window from the start, so
    /// setting off the other way leapt straight to the finish's side and
    /// ticked every checkpoint (2026-09-25 review of #67/#68).
    static let leapSlackMeters = 40.0
    /// Within this far along of the start, the person is still at the start.
    static let startBandMeters = 15.0

    /// A checkpoint counts this far before its exact position, so the last
    /// few metres of GPS noise never hold a session up.
    static let reachSlack = 20.0
    /// Fixes that must agree before position jumps to another stretch.
    static let jumpConfirmFixes = 3
    /// Start and end this close make a closed line.
    static let closedMeters = 30.0

    init?(route: NavigableRoute) {
        guard let path = route.path, path.count >= 2 else { return nil }
        let guide = TrailGuide(path: path)
        var previous: Double?
        checkpointAlong = route.waypoints.map { waypoint in
            let along = guide.position(of: waypoint, near: previous)?.along ?? 0
            previous = along
            return along
        }
        self.guide = guide
        isLoop = route.isLoop
        isClosed = path.count > 2 && TrailWalkPlanner.meters(path[0], path[path.count - 1]) <= Self.closedMeters
    }

    /// Picks up from a known position: a restored session, or a route just
    /// turned round.
    mutating func resume(at along: Double) {
        self.along = min(max(0, along), guide.length)
        lastAcceptedLocation = nil
        pendingJump = nil
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
        // Look ahead as far as the person could have gone since the last
        // position counted, so a gap in fixes keeps following the same stretch
        // instead of taking whichever stretch is nearest (an out-and-back's
        // way home, 2026-09-25 review).
        let moved = lastAcceptedLocation.map { TrailWalkPlanner.meters($0, location) } ?? 0
        let ahead = TrailGuide.windowAhead + Self.windingFactor * moved
        let current = along ?? 0
        guard let found = guide.candidates(for: location, near: current, expectedAlong: current + moved,
                                           ahead: ahead) else { return nil }
        offset = found.best.offset
        nearest = found.best.nearest
        // Leaving has to be beyond doubt; coming back is judged as measured.
        alertOffset = monitor.isOffTrail ? found.best.offset : max(0, found.best.offset - max(0, accuracy))
        // Progress only moves while the person is on the trail. Off it, the
        // nearest point can be a different stretch entirely (on the simulator
        // it was 35 m further along), and counting that would tick off
        // checkpoints they never walked. The way back still updates.
        if found.best.offset <= OffTrailMonitor.leaveMeters {
            let chosen = found.preferred
            // Without a previous fix there is no distance moved to judge a leap by.
            let plausible = lastAcceptedLocation == nil
                || chosen.along - current <= Self.windingFactor * moved + Self.leapSlackMeters
            if chosen == found.inWindow, plausible, !isSettingOffBackward(to: chosen.along, from: current) {
                along = chosen.along
                lastAcceptedLocation = location
                pendingJump = nil
            } else {
                considerJump(to: chosen.along, at: location)
            }
        }
        guard alertsEnabled else {
            monitor.reset()
            return nil
        }
        return monitor.update(offset: alertOffset ?? found.best.offset, at: now)
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

    /// Still by the start of a closed line, and placed in its far half: the
    /// person has set off round it the other way, since walking forward they
    /// would have been counted along the first stretch on the way. Always
    /// needs agreement (`considerJump`), and it is the only way a route is
    /// turned round. The far half, at most the look-ahead, so a short loop's
    /// finish side counts; "by the start" rather than "before the first
    /// checkpoint", so a forward walker whose fixes lapse early on is not
    /// taken for one going backwards (2026-09-25 review of #67/#68).
    private func isSettingOffBackward(to candidate: Double, from current: Double) -> Bool {
        isClosed && current <= Self.startBandMeters
            && candidate > guide.length - min(TrailGuide.windowAhead, guide.length / 2)
    }

    /// The session could not turn the route round (it had already passed a
    /// checkpoint). Forget the request, or it is repeated on every fix and
    /// the position never moves.
    mutating func declineReverse() {
        isWalkingBackward = false
        reversedAlong = nil
    }

    /// Another stretch is clearly nearer than the one being followed: a
    /// shortcut, a detour that rejoined further on, a start in the middle —
    /// or a closed line being walked the other way. Wait for agreement.
    private mutating func considerJump(to candidate: Double, at location: CLLocationCoordinate2D) {
        if let pending = pendingJump,
           abs(candidate - pending.along) <= 50 + Self.windingFactor * TrailWalkPlanner.meters(pending.location, location) {
            pendingJump = (candidate, pending.count + 1, location)
        } else {
            pendingJump = (candidate, 1, location)
        }
        guard let pending = pendingJump, pending.count >= Self.jumpConfirmFixes else { return }
        pendingJump = nil
        if isSettingOffBackward(to: candidate, from: along ?? 0) {
            // Still by the start, and now steadily on the line's last stretch:
            // they set off the other way round.
            isWalkingBackward = true
            reversedAlong = guide.length - candidate
            return
        }
        along = candidate
        lastAcceptedLocation = location
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
