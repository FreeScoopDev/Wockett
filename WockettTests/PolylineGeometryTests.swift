import Testing
import MapKit
@testable import PoCSquat

/// Regression guard for `MKPolyline.coordinate(atFraction:)`, which walks a
/// route line to find the coordinate a given fraction along it. Until 1.12 this
/// lived as two identical `coordAlong` copies in `RouteFinderMapView` and
/// `NavigationMapView`; both callers now share the one implementation, so a
/// single set of assertions covers both the route preview and live navigation.
///
/// The original guard read
///
///     guard n > 1, fraction > 0 else { return polyline.points()[0].coordinate }
///
/// which looks like a safe fallback but is not: `points()` is an unchecked C
/// array, so on a polyline with zero points `points()[0]` reads past the end and
/// traps the whole process. MKDirections can return a degenerate route — no
/// walkable path, a bad location fix, poor connectivity — so an empty polyline is
/// reachable in ordinary use, not just in tests.
struct PolylineGeometryTests {

    private func line(_ coords: [CLLocationCoordinate2D]) -> MKPolyline {
        var c = coords
        return MKPolyline(coordinates: &c, count: c.count)
    }

    private func approxEqual(_ a: CLLocationCoordinate2D?,
                             _ b: CLLocationCoordinate2D,
                             tolerance: Double = 1e-6) -> Bool {
        guard let a else { return false }
        return abs(a.latitude - b.latitude) < tolerance
            && abs(a.longitude - b.longitude) < tolerance
    }

    @Test("An empty polyline returns nil rather than trapping")
    func emptyPolylineReturnsNil() {
        let empty = MKPolyline()
        #expect(empty.pointCount == 0, "Precondition: this polyline should hold no points")
        #expect(empty.coordinate(atFraction: 0.5) == nil)
    }

    @Test("A single-point polyline returns that point")
    func singlePointReturnsThatPoint() {
        let only = CLLocationCoordinate2D(latitude: 40.7589, longitude: -73.9851)
        let one  = line([only])
        #expect(approxEqual(one.coordinate(atFraction: 0.5), only))
    }

    @Test("A fraction of 1 or more returns the final point")
    func fullFractionReturnsLastPoint() {
        let start = CLLocationCoordinate2D(latitude: 40.0, longitude: -73.0)
        let end   = CLLocationCoordinate2D(latitude: 41.0, longitude: -73.0)
        let two   = line([start, end])
        #expect(approxEqual(two.coordinate(atFraction: 1.0), end))
        #expect(approxEqual(two.coordinate(atFraction: 1.5), end))
    }

    @Test("A fraction of zero returns the starting point")
    func zeroFractionReturnsFirstPoint() {
        let start = CLLocationCoordinate2D(latitude: 40.0, longitude: -73.0)
        let end   = CLLocationCoordinate2D(latitude: 41.0, longitude: -73.0)
        let two   = line([start, end])
        #expect(approxEqual(two.coordinate(atFraction: 0), start))
    }

    @Test("A midpoint fraction lands between the endpoints")
    func midFractionLandsBetweenEndpoints() {
        let start = CLLocationCoordinate2D(latitude: 40.0, longitude: -73.0)
        let end   = CLLocationCoordinate2D(latitude: 41.0, longitude: -73.0)
        let two   = line([start, end])
        let mid   = two.coordinate(atFraction: 0.5)
        #expect(mid != nil)
        if let mid {
            #expect(mid.latitude > start.latitude && mid.latitude < end.latitude)
        }
    }
}
