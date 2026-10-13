import Foundation
import CoreLocation
import MapKit

/// What a shared route publishes instead of the whole path: the route without
/// at least its first and last 200 m, measured along the waypoints. Most walks
/// start and end at home, and anyone can read a shared route. The route the
/// user keeps on the phone is never changed.
///
/// Only original waypoints are published, never a point made up on a leg: on
/// a planned route a leg is a straight line from home, so a cut point placed
/// exactly 200 m along it, next to the leg's far end, points straight back at
/// the door (critic, 2026-10-13). Each end also loses a further 0-100 m that
/// varies from route to route, so the cut can't be measured back from a known
/// 200 m on a recorded walk either.
///
/// Pure, so the rules are tested without CloudKit.
enum SharedRouteTrim {
    /// Always left off each end of a shared route, in metres.
    static let trimMeters: Double = 200
    /// Up to this much more comes off each end, chosen per route (`extraTrim`).
    static let maxExtraMeters: Double = 100
    /// The shortest route that can be shared: both trims plus as much again.
    static let minimumMeters: Double = 600

    struct Trimmed: Equatable {
        /// The path to publish: original waypoints only.
        let waypoints: [WaypointCoord]
        /// Length along the waypoints before trimming (a loop includes its
        /// closing leg back to the start).
        let fullMeters: Double
        /// Length along the published waypoints.
        let keptMeters: Double

        /// The distance to publish. `totalDistance` (from walking directions
        /// for a planned route) scaled by the share of the path kept, so it
        /// describes the published route, not the private one. Falls back to
        /// the kept length.
        func publishedDistance(totalDistance: Double) -> Double {
            guard totalDistance.isFinite, totalDistance > 0, fullMeters > 0 else { return keptMeters }
            return totalDistance * keptMeters / fullMeters
        }
    }

    enum Outcome: Equatable {
        case trimmed(Trimmed)
        /// Shorter than `minimumMeters` along its waypoints: not shared.
        case tooShort(fullMeters: Double)
        /// Long enough, but fewer than two of its waypoints lie past the cuts
        /// (a planned route with few stops): not shared, because publishing
        /// part of a leg from home would show where that leg starts.
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
        case .tooFewPoints:
            return "This route has too few stops to share without showing where it starts. "
                + "A route with more stops, or a walk you recorded, can be shared."
        }
    }

    /// The trimmed path. A loop is closed first (its stored waypoints don't
    /// repeat the start), so its last stretch is the leg back to the start.
    /// `extra` is added to `trimMeters` at the start and end respectively.
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

        let startAt = trimMeters + max(0, extra.start)
        let endAt = full - trimMeters - max(0, extra.end)
        var kept: [WaypointCoord] = []
        for i in path.indices where cumulative[i] >= startAt && cumulative[i] <= endAt {
            if path[i] != kept.last { kept.append(path[i]) }
        }
        guard kept.count >= 2 else { return .tooFewPoints }

        var keptLength = 0.0
        for i in kept.indices.dropFirst() { keptLength += distance(kept[i - 1], kept[i]) }
        return .trimmed(Trimmed(waypoints: kept, fullMeters: full, keptMeters: keptLength))
    }

    /// The trim for a saved route: `extra` comes from its id, so sharing the
    /// same route twice cuts it in the same places and can't be compared.
    static func trim(_ route: CustomRoute) -> Outcome {
        trim(route.waypoints, isLoop: route.isLoop, extra: extraTrim(for: route.id))
    }

    /// 0-100 m for each end, fixed by `id`.
    static func extraTrim(for id: UUID) -> (start: Double, end: Double) {
        let bytes = id.uuid
        return (Double(bytes.0) / 255 * maxExtraMeters, Double(bytes.15) / 255 * maxExtraMeters)
    }

    /// `metres` in the user's units, as the share screens show it.
    static func formatted(_ metres: Double) -> String {
        MKDistanceFormatter.abbreviated.string(fromDistance: metres)
    }

    private static func distance(_ a: WaypointCoord, _ b: WaypointCoord) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
