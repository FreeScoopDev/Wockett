import CoreLocation
import Testing
@testable import PoCSquat

/// The Start button on a route planned from a chosen place asks this before it
/// starts recording (spec fix/route-start-far-from-here).
struct StartReachTests {
    private static let raleigh = CLLocationCoordinate2D(latitude: 35.7796, longitude: -78.6382)

    @Test func samePointIsNear() {
        #expect(StartReach.check(live: Self.raleigh, routeStart: Self.raleigh) == .near)
    }

    @Test func aCarParkAwayIsNear() {
        // About 300 m north.
        let nearby = CLLocationCoordinate2D(latitude: 35.7796 + 0.0027, longitude: -78.6382)
        #expect(StartReach.check(live: nearby, routeStart: Self.raleigh) == .near)
    }

    @Test func anotherTownIsFarAndSaysHowFar() throws {
        // Durham is about 35 km from Raleigh.
        let durham = CLLocationCoordinate2D(latitude: 35.9940, longitude: -78.8986)
        guard case let .far(meters) = StartReach.check(live: durham, routeStart: Self.raleigh) else {
            Issue.record("expected .far")
            return
        }
        #expect(meters > 30_000 && meters < 40_000)
    }

    @Test func missingPositionsAreUnknownNotFar() {
        #expect(StartReach.check(live: nil, routeStart: Self.raleigh) == .unknown)
        #expect(StartReach.check(live: Self.raleigh, routeStart: nil) == .unknown)
        #expect(StartReach.check(live: nil, routeStart: nil) == .unknown)
    }

    @Test func theThresholdIsTheLine() {
        // 1 degree of latitude is about 111.2 km: a 111.2 km threshold flips.
        let a = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let b = CLLocationCoordinate2D(latitude: 1, longitude: 0)
        let metres = StartReach.distanceMeters(a, b)
        #expect(StartReach.check(live: a, routeStart: b, thresholdMeters: metres + 1) == .near)
        #expect(StartReach.check(live: a, routeStart: b, thresholdMeters: metres - 1) != .near)
    }

    @Test func acrossTheDateLineIsShortNotHalfTheWorld() {
        let west = CLLocationCoordinate2D(latitude: 0, longitude: 179.999)
        let east = CLLocationCoordinate2D(latitude: 0, longitude: -179.999)
        #expect(StartReach.distanceMeters(west, east) < 500)
    }

    @Test func theDistanceDoesNotDependOnWhatWasMeasuredBefore() {
        // CLLocation.distance caches a scale between calls; this must not.
        let far = StartReach.distanceMeters(Self.raleigh, CLLocationCoordinate2D(latitude: 40.7, longitude: -74.0))
        _ = StartReach.distanceMeters(Self.raleigh, CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64))
        #expect(StartReach.distanceMeters(Self.raleigh, CLLocationCoordinate2D(latitude: 40.7, longitude: -74.0)) == far)
    }
}
