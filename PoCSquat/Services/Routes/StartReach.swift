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
