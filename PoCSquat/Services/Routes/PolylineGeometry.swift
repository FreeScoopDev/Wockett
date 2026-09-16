import MapKit
import CoreLocation

// Geometry that walks a route line. This is the single home for `coordinate(atFraction:)`.
//
// It used to be two byte-identical `static func coordAlong` copies, one in
// `RouteFinderMapView` and one in `NavigationMapView`. The empty-polyline crash
// (an unchecked `points()[0]` read) existed in both, and a fix applied to one
// would have left the bug live on the navigation path. It happened to be caught;
// next time it might not be. Keep one copy so a fix is a fix everywhere.

extension MKPolyline {

    /// The coordinate a given fraction (0...1) of the way along this line,
    /// measured by ground distance across the segments, or nil when the line
    /// holds no points at all.
    ///
    /// `points()` is an unchecked C array — on an empty polyline `points()[0]`
    /// reads past the end and traps the process rather than returning nil.
    /// MKDirections can hand back a degenerate route (no walkable path, a bad
    /// fix, poor connectivity), so the empty case is reachable in ordinary use.
    func coordinate(atFraction fraction: Double) -> CLLocationCoordinate2D? {
        let n = pointCount
        guard n > 0 else { return nil }
        guard n > 1, fraction > 0 else { return points()[0].coordinate }
        if fraction >= 1 { return points()[n - 1].coordinate }
        let pts = points()
        var total = 0.0
        var lens = [Double]()
        for i in 0..<n - 1 {
            let a = CLLocation(latitude: pts[i].coordinate.latitude, longitude: pts[i].coordinate.longitude)
            let b = CLLocation(latitude: pts[i + 1].coordinate.latitude, longitude: pts[i + 1].coordinate.longitude)
            let seg = a.distance(from: b)
            lens.append(seg); total += seg
        }
        let target = total * fraction
        var accum = 0.0
        for i in 0..<lens.count {
            guard lens[i] > 0 else { accum += lens[i]; continue }
            if accum + lens[i] >= target {
                let t = (target - accum) / lens[i]
                let a = pts[i].coordinate, b = pts[i + 1].coordinate
                return CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t
                )
            }
            accum += lens[i]
        }
        return pts[n - 1].coordinate
    }
}
