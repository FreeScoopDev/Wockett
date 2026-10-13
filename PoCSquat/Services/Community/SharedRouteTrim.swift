import Foundation
import CoreLocation
import MapKit

/// What a shared route publishes instead of the whole path: the route without
/// its first and last 200 m, measured along the waypoints. Most walks start and
/// end at home, and the public `SharedRoute` record is readable by anyone
/// (2026-10-12 audit, finding 1: one account's nine routes started within 9 m of
/// each other). The route the user keeps on the phone is never changed.
///
/// Pure, so the rules are tested without CloudKit.
enum SharedRouteTrim {
    /// Left off each end of a shared route, in metres.
    static let trimMeters: Double = 200
    /// The shortest route that can be shared: both trims plus as much again.
    static let minimumMeters: Double = 600

    struct Trimmed: Equatable {
        /// The path to publish: starts and ends exactly `trimMeters` in.
        let waypoints: [WaypointCoord]
        /// Length along the waypoints before trimming (a loop includes its
        /// closing leg back to the start).
        let fullMeters: Double
        /// Length along the published waypoints.
        let keptMeters: Double

        /// The distance to publish. `totalDistance` (from walking directions
        /// for a planned route, whose waypoints are sparse control points)
        /// scaled by the share of the path kept, so it describes the published
        /// route, not the private one. Falls back to the kept length.
        func publishedDistance(totalDistance: Double) -> Double {
            guard totalDistance.isFinite, totalDistance > 0, fullMeters > 0 else { return keptMeters }
            return totalDistance * keptMeters / fullMeters
        }
    }

    enum Outcome: Equatable {
        case trimmed(Trimmed)
        /// Shorter than `minimumMeters` along its waypoints: not shared.
        case tooShort(fullMeters: Double)
    }

    /// Thrown by `CommunityRouteService.publish` for a route too short to trim.
    struct TooShortError: LocalizedError, Equatable {
        var errorDescription: String? { message }
        var message: String {
            "This route is too short to share. Wockett leaves off the first and last "
                + "\(SharedRouteTrim.formatted(trimMeters)) of a shared route, so it needs to be at least "
                + "\(SharedRouteTrim.formatted(minimumMeters)) long."
        }
    }

    /// The trimmed path. A loop is closed first (its stored waypoints don't
    /// repeat the start), so its last stretch is the leg back to the start.
    static func trim(_ waypoints: [WaypointCoord], isLoop: Bool) -> Outcome {
        var path = waypoints
        if isLoop, let first = path.first, let last = path.last, first != last {
            path.append(first)
        }
        var cumulative = [0.0]
        for i in path.indices.dropFirst() {
            cumulative.append(cumulative[i - 1] + distance(path[i - 1], path[i]))
        }
        let full = cumulative.last ?? 0
        guard full >= minimumMeters else { return .tooShort(fullMeters: full) }

        let startAt = trimMeters
        let endAt = full - trimMeters
        var kept = [point(at: startAt, path: path, cumulative: cumulative)]
        for i in path.indices where cumulative[i] > startAt && cumulative[i] < endAt {
            if path[i] != kept.last { kept.append(path[i]) }
        }
        kept.append(point(at: endAt, path: path, cumulative: cumulative))

        var keptLength = 0.0
        for i in kept.indices.dropFirst() { keptLength += distance(kept[i - 1], kept[i]) }
        return .trimmed(Trimmed(waypoints: kept, fullMeters: full, keptMeters: keptLength))
    }

    /// `metres` in the user's units, as the share screens show it.
    static func formatted(_ metres: Double) -> String {
        MKDistanceFormatter.abbreviated.string(fromDistance: metres)
    }

    // MARK: - Geometry

    private static func distance(_ a: WaypointCoord, _ b: WaypointCoord) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// The point `target` metres along the path, interpolated within its
    /// segment. Zero-length segments (duplicate points) are skipped.
    private static func point(at target: Double, path: [WaypointCoord], cumulative: [Double]) -> WaypointCoord {
        for i in path.indices.dropFirst() where cumulative[i] >= target {
            let length = cumulative[i] - cumulative[i - 1]
            guard length > 0 else { continue }
            let t = (target - cumulative[i - 1]) / length
            let a = path[i - 1], b = path[i]
            return WaypointCoord(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                        longitude: a.longitude + (b.longitude - a.longitude) * t))
        }
        return path[path.count - 1]
    }
}
