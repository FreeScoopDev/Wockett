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

struct TrailWalkPlan: Equatable {
    let name: String
    /// The line the session draws and the person follows, starting where they are.
    let path: [CLLocationCoordinate2D]
    /// Checkpoints along `path`. `waypoints[0]` is the start, as NavigationSession expects.
    let waypoints: [CLLocationCoordinate2D]
    let isLoop: Bool
    let distanceMeters: Double

    func navigableRoute(activityMode: ActivityMode) -> NavigableRoute {
        NavigableRoute(name: name, waypoints: waypoints, lapCount: 1, isLoop: isLoop,
                       totalDistance: distanceMeters, activityMode: activityMode, path: path)
    }

    static func == (lhs: TrailWalkPlan, rhs: TrailWalkPlan) -> Bool {
        lhs.name == rhs.name && lhs.isLoop == rhs.isLoop && lhs.distanceMeters == rhs.distanceMeters
            && lhs.path.count == rhs.path.count
            && zip(lhs.path, rhs.path).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
    }
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

    /// A walk along `section` from the point nearest `location`, or nil if the
    /// person is not at the trail or the geometry is too short to walk.
    static func plan(for section: TrailFeature, name: String, from location: CLLocationCoordinate2D) -> TrailWalkPlan? {
        guard BundledTrailSource.distanceMeters(from: location, to: section) <= startRadiusMeters else { return nil }
        var coords = section.coordinates
        guard coords.count >= 2 else { return nil }
        let nearest = nearestIndex(in: coords, to: location)

        let path: [CLLocationCoordinate2D]
        if section.isLoop {
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

        return TrailWalkPlan(name: name, path: path,
                             waypoints: checkpoints(along: path, isLoop: section.isLoop, length: distance),
                             isLoop: section.isLoop, distanceMeters: distance)
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
                              path: back, pathIsRecording: pathIsRecording)
    }
}
