import Foundation
import CoreLocation
import CryptoKit
import MapKit

/// What a shared route publishes instead of the whole path. Most walks start
/// and end at home, and anyone can read a shared route; the route the user
/// keeps on the phone is never changed. Rules, each from a way the start was
/// recovered in review (critic, 2026-10-13):
///
/// - **Only a path, never control points.** The input must be the line the
///   route follows (a recording, or walking directions), not the few points a
///   route was planned from: a suggested loop's points are three corners of a
///   square whose fourth corner is home.
/// - **A privacy zone, not just a distance along the path.** Every point within
///   200 m plus a 0-100 m per-route extra *in a straight line* of the start or
///   the end goes, as does the first and last 200 m plus extra *along the path*,
///   so a walk that passes the door again publishes nothing there either.
/// - **One unbroken stretch.** Of what is left, only the longest run of
///   consecutive points is published, so the line never jumps across a zone.
/// - **Evenly respaced.** That run is redrawn every 10 m, so a published point
///   is never a planning corner, and other phones follow it as a recorded
///   line (`RecordedRoute`) instead of asking for directions between hundreds
///   of points.
///
/// This hides the exact start and finish, not the area around them.
enum SharedRouteTrim {
    /// The least left off each end, along the path and in a straight line.
    static let trimMeters: Double = 200
    /// Up to this much more comes off each end, chosen per route (`extraTrim`).
    static let maxExtraMeters: Double = 100
    /// The shortest route that can be shared.
    static let minimumMeters: Double = 600
    /// Spacing of the published points.
    static let spacingMeters: Double = 10
    /// A path has at least this many points, at most this far apart (median).
    /// Planned routes' control points are hundreds of metres apart; walking
    /// directions and recordings are tens of metres or less.
    static let minimumPathPoints = 10
    static let maxMedianSpacingMeters: Double = 100

    struct Trimmed: Equatable {
        /// The points to publish: every `spacingMeters` along the kept stretch.
        let waypoints: [WaypointCoord]
        /// Length along the path before trimming (a loop includes its leg home).
        let fullMeters: Double
        /// Length of the kept stretch.
        let keptMeters: Double

        /// The distance to publish: `totalDistance` scaled by the share of the
        /// path kept, so it describes the published route, not the private
        /// one. Falls back to the kept length.
        func publishedDistance(totalDistance: Double) -> Double {
            guard totalDistance.isFinite, totalDistance > 0, fullMeters > 0 else { return keptMeters }
            return totalDistance * keptMeters / fullMeters
        }
    }

    enum Outcome: Equatable {
        case trimmed(Trimmed)
        /// Shorter than `minimumMeters`: not shared.
        case tooShort(fullMeters: Double)
        /// Planning points rather than a path: not shared as they are.
        case notAPath
        /// Nothing long enough is left outside the zones (a route that stays
        /// near its start): not shared.
        case tooFewPoints
    }

    /// Thrown by `CommunityRouteService.publish` for a route that can't be trimmed.
    struct CannotShareError: LocalizedError, Equatable {
        let outcome: Outcome
        var errorDescription: String? { message }
        var message: String { SharedRouteTrim.message(for: outcome) ?? "" }
    }

    /// Why a route can't be shared, or nil when it can.
    static func message(for outcome: Outcome) -> String? {
        switch outcome {
        case .trimmed:
            return nil
        case .tooShort:
            return "This route is too short to share. Wockett leaves off at least the first and last "
                + "\(formatted(trimMeters)) of a shared route, so it needs to be \(formatted(minimumMeters)) or longer."
        case .notAPath:
            return "Wockett needs this route's full path to hide where it starts. Try again once the map has loaded."
        case .tooFewPoints:
            return "Too little of this route is far enough from where it starts and ends to share it."
        }
    }

    /// The trimmed path. A loop is closed first if its points don't already
    /// return to the start. `extra` is added to `trimMeters` at each end.
    static func trim(_ waypoints: [WaypointCoord], isLoop: Bool,
                     extra: (start: Double, end: Double) = (0, 0)) -> Outcome {
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
        guard isPath(path) else { return .notAPath }

        let start = path[0], end = path[path.count - 1]
        let startCut = trimMeters + min(maxExtraMeters, max(0, extra.start))
        let endCut = trimMeters + min(maxExtraMeters, max(0, extra.end))
        let eligible = path.indices.map { i in
            cumulative[i] >= startCut && cumulative[i] <= full - endCut
                && distance(path[i], start) >= startCut && distance(path[i], end) >= endCut
        }

        // The longest run of consecutive eligible points, by length.
        var best: Range<Int>?
        var bestLength = -1.0
        var runStart: Int?
        for i in path.indices.map({ $0 }) + [path.count] {
            if i < path.count, eligible[i] {
                if runStart == nil { runStart = i }
                continue
            }
            if let s = runStart {
                let run = s..<i
                if length(run, cumulative) > bestLength { best = run; bestLength = length(run, cumulative) }
                runStart = nil
            }
        }
        guard let run = best, run.count >= 2, length(run, cumulative) > 0 else { return .tooFewPoints }

        let kept = length(run, cumulative)
        let points = resample(Array(path[run]), cumulative: run.map { cumulative[$0] - cumulative[run.lowerBound] })
        return .trimmed(Trimmed(waypoints: points, fullMeters: full, keptMeters: kept))
    }

    /// The trim for a saved route: `extra` comes from its id, so sharing the
    /// same route twice cuts it in the same places.
    static func trim(_ route: CustomRoute) -> Outcome {
        trim(route.waypoints, isLoop: route.isLoop, extra: extraTrim(for: route.id))
    }

    /// 0-100 m for each end, fixed by `id`.
    static func extraTrim(for id: UUID) -> (start: Double, end: Double) {
        let bytes = id.uuid
        return (Double(bytes.0) / 255 * maxExtraMeters, Double(bytes.15) / 255 * maxExtraMeters)
    }

    /// An id that is the same every time for the same points, so a path built
    /// afresh for each share (a route finder suggestion) keeps one `extraTrim`.
    static func stableID(for points: [WaypointCoord]) -> UUID {
        var hasher = SHA256()
        for p in points {
            withUnsafeBytes(of: p.latitude.bitPattern) { hasher.update(bufferPointer: $0) }
            withUnsafeBytes(of: p.longitude.bitPattern) { hasher.update(bufferPointer: $0) }
        }
        let b = Array(hasher.finalize())
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// `metres` in the user's units, as the share screens show it.
    static func formatted(_ metres: Double) -> String {
        MKDistanceFormatter.abbreviated.string(fromDistance: metres)
    }

    // MARK: - Geometry

    static func isPath(_ points: [WaypointCoord]) -> Bool {
        guard points.count >= minimumPathPoints else { return false }
        let spacings = zip(points, points.dropFirst()).map { distance($0, $1) }.sorted()
        return spacings[spacings.count / 2] <= maxMedianSpacingMeters
    }

    private static func length(_ run: Range<Int>, _ cumulative: [Double]) -> Double {
        cumulative[run.upperBound - 1] - cumulative[run.lowerBound]
    }

    /// A point every `spacingMeters` from the first, plus the last.
    /// `along[i]` is `points[i]`'s distance from `points[0]`.
    private static func resample(_ points: [WaypointCoord], cumulative along: [Double]) -> [WaypointCoord] {
        let total = along[along.count - 1]
        var out = [points[0]]
        var segment = 1
        var target = spacingMeters
        while target < total {
            while along[segment] < target { segment += 1 }
            let a = points[segment - 1], b = points[segment]
            let span = along[segment] - along[segment - 1]
            let t = span > 0 ? (target - along[segment - 1]) / span : 0
            out.append(WaypointCoord(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                            longitude: a.longitude + (b.longitude - a.longitude) * t)))
            target += spacingMeters
        }
        if let last = points.last, out.last != last { out.append(last) }
        return out
    }

    private static func distance(_ a: WaypointCoord, _ b: WaypointCoord) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
