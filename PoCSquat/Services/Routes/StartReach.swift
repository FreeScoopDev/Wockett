import CoreLocation
import Foundation

/// Whether the person is anywhere near where a route begins, for the Start
/// button on a route planned from a chosen place (not from where they are).
///
/// Pure: it takes two coordinates and returns an answer, with its own distance
/// calculation. `CLLocation.distance(from:)` is not a pure function (it caches
/// a projection scale in a process-wide static, see CLAUDE.md), and an answer
/// that depends on whatever was measured last is wrong for a check that has to
/// give the same answer twice.
enum StartReach: Equatable {
    /// Close enough to start from here.
    case near
    /// Further than `thresholdMeters` from the route's first point.
    case far(meters: Double)
    /// Either position is missing (location off, restricted, no fix, or a
    /// route with no points): nothing to compare, so do not get in the way.
    case unknown

    /// How far from a route's first point still counts as "there": a car park
    /// by the trailhead is, another town is not.
    static let thresholdMeters: Double = 1_000

    /// How old a location fix may be and still count as "where the person is".
    /// `RouteManager.lastLocation` is only refreshed by a live search, a
    /// permission change and a few screens, so after planning at home and
    /// driving to the trailhead it can be hours old. Start therefore takes a
    /// fresh fix when it is tapped (asking for no more than this age), and an
    /// older one never makes it say the route is far away.
    static let maxFixAgeSeconds: TimeInterval = 120

    /// The coordinate of a fix that is recent enough, else nil (`.unknown`).
    static func freshCoordinate(_ fix: CLLocation?,
                                now: Date = Date(),
                                maxAge: TimeInterval = StartReach.maxFixAgeSeconds) -> CLLocationCoordinate2D? {
        guard let fix, now.timeIntervalSince(fix.timestamp) <= maxAge else { return nil }
        return fix.coordinate
    }

    /// What Start does, given the fix taken when it was tapped.
    enum Decision: Equatable {
        case startNow
        case askFar(meters: Double)
    }

    /// Ask only when a recent fix puts the person further than the threshold
    /// from the route's first point. No fix, an old one, or a close one: start.
    static func decision(fix: CLLocation?,
                         routeStart: CLLocationCoordinate2D?,
                         now: Date = Date()) -> Decision {
        if case let .far(meters) = check(live: freshCoordinate(fix, now: now), routeStart: routeStart) {
            return .askFar(meters: meters)
        }
        return .startNow
    }

    static func check(live: CLLocationCoordinate2D?,
                      routeStart: CLLocationCoordinate2D?,
                      thresholdMeters: Double = StartReach.thresholdMeters) -> StartReach {
        guard let live, let routeStart else { return .unknown }
        let meters = distanceMeters(live, routeStart)
        return meters > thresholdMeters ? .far(meters: meters) : .near
    }

    /// Great-circle distance on a sphere of Earth's mean radius. That is off by
    /// well under 1% from the ellipsoid, which is nothing against a 1 km line.
    static func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let earthRadius = 6_371_008.8
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }
}
