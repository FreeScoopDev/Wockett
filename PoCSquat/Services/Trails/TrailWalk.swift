import CoreLocation
import Foundation

// MARK: - Walking a trail
//
// Turns a trail section into a guided session that follows the trail's own
// line. Every other guided route asks MKDirections for the way between its
// waypoints, which routes on Apple's street network and would pull a trail
// walk onto the roads beside it; a trail walk carries its geometry as
// `NavigableRoute.path` instead, and the waypoints are only checkpoints.
//
// Start Walk is offered only at the trail (Joe, 2026-09-23): within
// `startRadiusMeters` of the section. The walk begins at the trail point
// nearest the person — a loop goes all the way round from there, a line goes
// to whichever end is farther.
//
// Out and back (2026-10-09). A line walked "to the farther end" was a 10 or
// 30 mile one-way plan on a long greenway, ending far from the car, so people
// would stop partway and leave a route they never finished. Joe: "we can't
// expect the users to complete the entire trail if they are long… It should
// be somewhat seamless." A walk now has a target (`TrailWalkTarget`): a round
// trip of a chosen distance goes out half of it along the trail and comes
// back the same way, turning at `turnaroundMeters`; the whole trail is still
// offered. The path retraces itself, which TrailProgress already follows (a
// recorded out-and-back is the same shape).

struct TrailWalkPlan: Equatable {
    let name: String
    /// The line the session draws and the person follows, starting where they are.
    let path: [CLLocationCoordinate2D]
    /// Checkpoints along `path`. `waypoints[0]` is the start, as NavigationSession expects.
    let waypoints: [CLLocationCoordinate2D]
    let isLoop: Bool
    let distanceMeters: Double
    /// True when the walk covers only the section the person is at, not the
    /// whole grouped trail (a group whose pieces don't form one line).
    var isSectionOnly = false
    /// Out and back: where along `path` to turn round (half the walk), nil
    /// for a walk to the end or round a loop.
    var turnaroundMeters: Double?
    /// An out-and-back that reached the trail's end before its target: it
    /// turns there, so it is shorter than asked.
    var turnsAtTrailEnd = false

    func navigableRoute(activityMode: ActivityMode) -> NavigableRoute {
        NavigableRoute(name: name, waypoints: waypoints, lapCount: 1, isLoop: isLoop,
                       totalDistance: distanceMeters, activityMode: activityMode, path: path,
                       turnaroundMeters: turnaroundMeters)
    }

    static func == (lhs: TrailWalkPlan, rhs: TrailWalkPlan) -> Bool {
        lhs.name == rhs.name && lhs.isLoop == rhs.isLoop && lhs.distanceMeters == rhs.distanceMeters
            && lhs.path.count == rhs.path.count
            && zip(lhs.path, rhs.path).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
    }
}

/// What a trail walk covers.
enum TrailWalkTarget: Hashable {
    /// Round a loop, or to the farther end of a line.
    case whole
    /// Out along the trail and back the same way, this far in all.
    case roundTrip(meters: Double)
}

enum TrailWalkPlanner {

    /// How close counts as "at the trail".
    static let startRadiusMeters = 150.0
    /// Target spacing between checkpoints. Sparse on purpose: the trail data
    /// and Apple's map can disagree by tens of metres (2026-09-24), and a
    /// session only advances by reaching each checkpoint in turn.
    static let checkpointSpacingMeters = 800.0

    /// The section of `item` the person is at, nearest first, or nil.
    static func section(of item: TrailListItem, at location: CLLocationCoordinate2D?) -> TrailFeature? {
        guard let location else { return nil }
        return item.sections
            .map { ($0, BundledTrailSource.distanceMeters(from: location, to: $0)) }
            .filter { $0.1 <= startRadiusMeters }
            .min { $0.1 < $1.1 }?.0
    }

    /// The walk a row's Start button offers from `location`, or nil when the
    /// person is not at it.
    ///
    /// A group whose sections chain into one line (`TrailChain.stitch`) — every
    /// unnamed group, and a named one whose pieces happen to — is walked as
    /// that line, so Start on a 4 mi path split at every driveway follows the
    /// whole path rather than the 250 ft piece underfoot. Otherwise the walk
    /// covers the section the person is at; if that one is too short to walk
    /// from where they stand, the next-nearest section in reach is tried.
    static func plan(for item: TrailListItem, from location: CLLocationCoordinate2D?,
                     target: TrailWalkTarget = .whole) -> TrailWalkPlan? {
        guard let location else { return nil }
        if item.isGroup, let line = TrailChain.stitch(item.sections.map(\.coordinates)) {
            return plan(along: line.path, isLoop: line.isClosed, name: item.name, from: location, target: target)
        }
        let inReach = item.sections
            .map { ($0, BundledTrailSource.distanceMeters(from: location, to: $0)) }
            .filter { $0.1 <= startRadiusMeters }
            .sorted { $0.1 < $1.1 }
        for (section, _) in inReach {
            if var plan = plan(along: section.coordinates, isLoop: section.isLoop, name: item.name,
                               from: location, target: target) {
                plan.isSectionOnly = item.isGroup
                return plan
            }
        }
        return nil
    }

    /// A walk along `section` from the point nearest `location`, or nil if the
    /// person is not at the trail or the geometry is too short to walk.
    static func plan(for section: TrailFeature, name: String, from location: CLLocationCoordinate2D) -> TrailWalkPlan? {
        plan(along: section.coordinates, isLoop: section.isLoop, name: name, from: location)
    }

    /// A walk along `line` from its point nearest `location`: all the way round
    /// a loop, or to the farther end of a line.
    static func plan(along line: [CLLocationCoordinate2D], isLoop: Bool, name: String,
                     from location: CLLocationCoordinate2D, target: TrailWalkTarget = .whole) -> TrailWalkPlan? {
        guard BundledTrailSource.distanceMeters(from: location, toLine: line) <= startRadiusMeters else { return nil }
        var coords = line
        guard coords.count >= 2 else { return nil }
        let nearest = nearestIndex(in: coords, to: location)

        let path: [CLLocationCoordinate2D]
        if isLoop {
            if coords.count > 2, meters(coords[0], coords[coords.count - 1]) < 1 { coords.removeLast() }
            let from = min(nearest, coords.count - 1)
            let ring = Array(coords[from...] + coords[..<from])
            path = ring + [ring[0]]
        } else {
            let toEnd = length(Array(coords[nearest...]))
            let toStart = length(Array(coords[...nearest]))
            path = toEnd >= toStart ? Array(coords[nearest...]) : Array(coords[...nearest].reversed())
        }
        let distance = length(path)
        guard path.count >= 2, distance >= 50 else { return nil }

        if case .roundTrip(let meters) = target {
            // The loop's ring or the line toward its farther end, walked out
            // half the target and back.
            let out = min(meters / 2, distance)
            let outPath = prefix(of: path, meters: out)
            guard outPath.count >= 2, out >= 25 else { return nil }
            let roundTrip = outPath + outPath.reversed().dropFirst()
            let total = length(roundTrip)
            var plan = TrailWalkPlan(name: name, path: roundTrip,
                                     waypoints: checkpoints(along: roundTrip, isLoop: false, length: total),
                                     isLoop: false, distanceMeters: total)
            plan.turnaroundMeters = length(outPath)
            plan.turnsAtTrailEnd = !isLoop && meters / 2 > distance + 1
            return plan
        }

        return TrailWalkPlan(name: name, path: path,
                             waypoints: checkpoints(along: path, isLoop: isLoop, length: distance),
                             isLoop: isLoop, distanceMeters: distance)
    }

    /// How far a person can go from where they stand before turning round:
    /// toward the farther end of a line, or half way round a loop (beyond
    /// that the full loop is the shorter way home).
    static func reach(for item: TrailListItem, from location: CLLocationCoordinate2D?) -> (meters: Double, isLoop: Bool)? {
        guard let whole = plan(for: item, from: location) else { return nil }
        return (whole.isLoop ? whole.distanceMeters / 2 : whole.distanceMeters, whole.isLoop)
    }

    /// The first `meters` of `path`, ending exactly there.
    static func prefix(of path: [CLLocationCoordinate2D], meters: Double) -> [CLLocationCoordinate2D] {
        guard let first = path.first else { return [] }
        var result = [first]
        var travelled = 0.0
        for (a, b) in zip(path, path.dropFirst()) {
            let segment = Self.meters(a, b)
            if travelled + segment >= meters {
                let t = segment > 0 ? (meters - travelled) / segment : 0
                result.append(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                     longitude: a.longitude + (b.longitude - a.longitude) * t))
                return result
            }
            result.append(b)
            travelled += segment
        }
        return result
    }

    /// Start, evenly spaced points, and — for a line — the end. A loop leaves
    /// its end out (the session completes a lap by returning to the start) but
    /// always has at least two checkpoints past the start, or the first one
    /// would be the start itself and the lap would finish on the spot.
    static func checkpoints(along path: [CLLocationCoordinate2D], isLoop: Bool, length: Double) -> [CLLocationCoordinate2D] {
        guard let first = path.first, let last = path.last else { return [] }
        let spacing = min(checkpointSpacingMeters, length / (isLoop ? 3 : 2))
        var result = [first]
        var target = spacing
        var travelled = 0.0
        for (a, b) in zip(path, path.dropFirst()) {
            let segment = meters(a, b)
            while segment > 0, travelled + segment >= target, target < length - spacing / 2 {
                let t = (target - travelled) / segment
                result.append(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                     longitude: a.longitude + (b.longitude - a.longitude) * t))
                target += spacing
            }
            travelled += segment
        }
        if !isLoop { result.append(last) }
        return result
    }

    // MARK: Geometry

    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    static func length(_ path: [CLLocationCoordinate2D]) -> Double {
        zip(path, path.dropFirst()).reduce(0) { $0 + meters($1.0, $1.1) }
    }

    private static func nearestIndex(in coords: [CLLocationCoordinate2D], to location: CLLocationCoordinate2D) -> Int {
        coords.indices.min { meters(coords[$0], location) < meters(coords[$1], location) } ?? 0
    }
}

extension NavigableRoute {
    /// The same line walked the other way, with checkpoints spaced from its
    /// new start the way the planner spaces them; nil for a route without a
    /// line. For a closed line (a loop, or a recording that came home), which
    /// can be set off round in either direction from its start.
    func reversedAlongLine() -> NavigableRoute? {
        guard let path, path.count >= 2 else { return nil }
        let back = Array(path.reversed())
        let length = TrailWalkPlanner.length(back)
        return NavigableRoute(name: name,
                              waypoints: TrailWalkPlanner.checkpoints(along: back, isLoop: isLoop, length: length),
                              lapCount: lapCount, isLoop: isLoop, totalDistance: totalDistance,
                              isCustomRoute: isCustomRoute, isCommunityRoute: isCommunityRoute,
                              activityMode: activityMode, customRouteId: customRouteId,
                              path: back, pathIsRecording: pathIsRecording,
                              // An out-and-back is symmetric; any turnaround mirrors.
                              turnaroundMeters: turnaroundMeters.map { length - $0 })
    }
}
