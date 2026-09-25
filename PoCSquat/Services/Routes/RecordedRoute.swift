import CoreLocation
import Foundation

// MARK: - Recorded routes
//
// A saved route whose waypoints are a recorded walk. "Save as Custom Route"
// keeps every point the session logged — one per ~5 m, the location manager's
// `distanceFilter` in every version so far — and so does a Past Walk started
// again. Every other guided route asks MKDirections for each leg between
// consecutive waypoints, and Apple refuses an app more than 50 requests in
// 10 s: a saved 1-mile walk (311 points) had 260 of its 310 requests refused
// the moment it was opened, and drew no line (simulator, 2026-09-24).
//
// Such a route is followed as its own line instead, the way a trail walk is,
// with a few checkpoints along it. It is recognised from the points rather
// than marked when saved: a stored flag would need a CloudKit schema change in
// both the private and the public (Community) database, and would leave every
// route already saved unmarked. A hand-built route is a few taps, each leg
// usually hundreds of metres; a recording is dozens of points metres apart.

enum RecordedRoute {

    /// Fewer points than this are routed as before — a handful of legs is
    /// well inside Apple's limit whatever made them.
    static let minimumPoints = 10
    /// Recordings are ~5 m apart — more on a fast ride, where the phone's
    /// once-a-second fix outruns the 5 m filter (15 m is 54 km/h). The median
    /// ignores the odd gap where fixes were dropped for poor accuracy. Kept
    /// tight because a hand-built route traced densely along a footpath
    /// would be misread as a recording, and would lose the builder.
    static let maxMedianSpacingMeters = 15.0

    struct Line {
        /// The line to draw and follow.
        let path: [CLLocationCoordinate2D]
        /// Checkpoints along `path`; `checkpoints[0]` is the start.
        let checkpoints: [CLLocationCoordinate2D]
    }

    static func isRecorded(_ points: [CLLocationCoordinate2D]) -> Bool {
        guard points.count >= minimumPoints else { return false }
        let spacings = zip(points, points.dropFirst())
            .map { TrailWalkPlanner.meters($0, $1) }
            .sorted()
        return spacings[spacings.count / 2] <= maxMedianSpacingMeters
    }

    /// The line to follow for `points`, or nil if they should be routed leg by leg.
    static func line(for points: [CLLocationCoordinate2D], isLoop: Bool) -> Line? {
        guard isRecorded(points) else { return nil }
        var path = points
        if isLoop, let first = path.first, let last = path.last,
           TrailWalkPlanner.meters(first, last) >= 1 {
            path.append(first)
        }
        let length = TrailWalkPlanner.length(path)
        guard length > 0 else { return nil }
        return Line(path: path,
                    checkpoints: TrailWalkPlanner.checkpoints(along: path, isLoop: isLoop, length: length))
    }
}

extension NavigableRoute {
    /// This route following its own line when its waypoints are a recording
    /// (see `RecordedRoute`); otherwise unchanged.
    func followingRecordedLine() -> NavigableRoute {
        guard path == nil, let line = RecordedRoute.line(for: waypoints, isLoop: isLoop) else { return self }
        return NavigableRoute(name: name, waypoints: line.checkpoints, lapCount: lapCount, isLoop: isLoop,
                              totalDistance: totalDistance, isCustomRoute: isCustomRoute,
                              isCommunityRoute: isCommunityRoute, activityMode: activityMode,
                              customRouteId: customRouteId, path: line.path, pathIsRecording: true)
    }
}
