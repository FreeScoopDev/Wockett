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
    /// prevent. After a long GPS gap the person is outside it, and a part of
    /// the trail that is clearly closer wins anyway.
    static let windowBehind = 100.0
    static let windowAhead = 250.0
    /// How much closer another part of the trail must be to win over the part
    /// the person has been following.
    static let switchMargin = 25.0

    /// The person's position on the line. With `previousAlong`, the stretch
    /// near where they were is preferred, so a trail that doubles back beside
    /// itself does not make progress jump to its other side; a part of the
    /// trail that is clearly closer still wins (a shortcut, or a wrong start).
    func position(of point: CLLocationCoordinate2D, near previousAlong: Double? = nil) -> Position? {
        guard path.count >= 2 else { return nil }
        var best: Position?
        var bestInWindow: Position?
        let lo = (previousAlong ?? 0) - Self.windowBehind
        let hi = (previousAlong ?? 0) + Self.windowAhead
        for i in 0..<(path.count - 1) {
            let candidate = project(point, onSegment: i)
            if best == nil || candidate.offset < best?.offset ?? .infinity { best = candidate }
            if previousAlong != nil, cumulative[i + 1] >= lo, cumulative[i] <= hi,
               bestInWindow == nil || candidate.offset < bestInWindow?.offset ?? .infinity {
                bestInWindow = candidate
            }
        }
        guard let best else { return nil }
        if let bestInWindow, bestInWindow.offset <= best.offset + Self.switchMargin { return bestInWindow }
        return best
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
struct TrailProgress {
    let guide: TrailGuide
    /// Distance along the line of each of the route's waypoints (checkpoints).
    let checkpointAlong: [Double]
    let isLoop: Bool

    private(set) var along: Double?
    private(set) var offset: Double?
    private(set) var nearest: CLLocationCoordinate2D?
    private(set) var monitor = OffTrailMonitor()

    /// A checkpoint counts this far before its exact position, so the last
    /// few metres of GPS noise never hold a session up.
    static let reachSlack = 20.0

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

    /// Feeds one location fix. Returns an off-trail event when one happens
    /// and alerts are on; position and progress update either way.
    mutating func update(location: CLLocationCoordinate2D, at now: Date, alertsEnabled: Bool) -> OffTrailMonitor.Event? {
        guard let position = guide.position(of: location, near: along) else { return nil }
        // Progress only moves while the person is on the trail. Off it, the
        // nearest point can be a different stretch entirely (on the simulator
        // it was 35 m further along), and counting that would tick off
        // checkpoints they never walked. The way back still updates.
        if along == nil || position.offset <= OffTrailMonitor.leaveMeters {
            along = position.along
        }
        offset = position.offset
        nearest = position.nearest
        guard alertsEnabled else {
            monitor.reset()
            return nil
        }
        return monitor.update(offset: position.offset, at: now)
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
        guard alertsEnabled, let offset else { return nil }
        return monitor.update(offset: offset, at: now)
    }
}

// MARK: - Directions in words

enum CompassDirection {
    /// "north", "northeast"… for a bearing in degrees clockwise from north.
    static func name(for bearing: Double) -> String {
        let names = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        let normalized = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((normalized + 22.5) / 45) % 8]
    }
}
