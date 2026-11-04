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

    /// Whether Start takes a fresh fix and may ask: only for a route planned from
    /// a chosen place, and only when location is already allowed. Any other
    /// state would make the fix request itself raise the permission prompt.
    static func needsFarCheck(hasChosenStart: Bool, location: RouteLocationState) -> Bool {
        hasChosenStart && location.base == .live
    }

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

    /// Ask only when a recent, usable fix puts the person further than the
    /// threshold from the route's first point even at the near edge of its
    /// error circle: `distance - horizontalAccuracy > threshold`. With Precise
    /// Location off, or a cached Wi-Fi fix, the reported point can be
    /// kilometres off, and that must not make Start say "far". A fix with a
    /// negative accuracy is invalid (Core Location's own convention). No fix,
    /// an old one, an invalid one, a close one, or one too vague to tell: start.
    static func decision(fix: CLLocation?,
                         routeStart: CLLocationCoordinate2D?,
                         now: Date = Date()) -> Decision {
        guard let fix, fix.horizontalAccuracy >= 0,
              case let .far(meters) = check(live: freshCoordinate(fix, now: now), routeStart: routeStart),
              meters - fix.horizontalAccuracy > thresholdMeters else { return .startNow }
        return .askFar(meters: meters)
    }

    /// What Start remembers at the tap, so it can tell after the fix comes
    /// back whether the screen still shows the same thing.
    struct Tap: Equatable {
        let routeID: UUID
        let activityMode: ActivityMode
    }

    /// Whether a Start tap may still act once its fix has come back: the same
    /// route is still selected, the activity is the one tapped, the Routes
    /// results are still showing (not Trails, not gone), and nothing (a sheet,
    /// the Terms, the route builder) is presented over them. Otherwise the walk
    /// it would start, or the question it would ask, is no longer what is on screen.
    static func tapStillCurrent(_ tap: Tap,
                                selectedRouteID: UUID?,
                                activityMode: ActivityMode,
                                showingRoutes: Bool,
                                presenting: Bool) -> Bool {
        showingRoutes && !presenting && selectedRouteID == tap.routeID && activityMode == tap.activityMode
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
