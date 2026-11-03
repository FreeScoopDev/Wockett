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

    // MARK: - How old a fix may be

    private static func fix(secondsAgo: TimeInterval, now: Date) -> CLLocation {
        CLLocation(coordinate: raleigh, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                   timestamp: now.addingTimeInterval(-secondsAgo))
    }

    @Test func aRecentFixIsUsed() {
        let now = Date()
        let used = StartReach.freshCoordinate(Self.fix(secondsAgo: 30, now: now), now: now)
        #expect(used?.latitude == Self.raleigh.latitude)
    }

    @Test func anOldFixIsNotWhereThePersonIs() {
        // Planned at home, drove to the trailhead: an hours-old fix must not
        // make Start claim the route is far away.
        let now = Date()
        #expect(StartReach.freshCoordinate(Self.fix(secondsAgo: 3 * 3600, now: now), now: now) == nil)
    }

    @Test func theFixAgeLimitIsTheLine() {
        let now = Date()
        let limit = StartReach.maxFixAgeSeconds
        #expect(StartReach.freshCoordinate(Self.fix(secondsAgo: limit - 1, now: now), now: now) != nil)
        #expect(StartReach.freshCoordinate(Self.fix(secondsAgo: limit + 1, now: now), now: now) == nil)
    }

    @Test func noFixIsNoCoordinate() {
        #expect(StartReach.freshCoordinate(nil) == nil)
    }

    // MARK: - What Start does

    private static let durham = CLLocationCoordinate2D(latitude: 35.9940, longitude: -78.8986)

    @Test func aRecentFixFarFromTheStartAsks() {
        let now = Date()
        let fix = CLLocation(coordinate: Self.durham, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                             timestamp: now)
        guard case let .askFar(meters) = StartReach.decision(fix: fix, routeStart: Self.raleigh, now: now) else {
            Issue.record("expected .askFar")
            return
        }
        #expect(meters > 30_000)
    }

    @Test func anOldFixNeverAsks() {
        let now = Date()
        let old = Self.fix(secondsAgo: 3 * 3600, now: now)   // at Raleigh, but old: must not matter
        let farAndOld = CLLocation(coordinate: Self.durham, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                                   timestamp: now.addingTimeInterval(-3 * 3600))
        #expect(StartReach.decision(fix: old, routeStart: Self.raleigh, now: now) == .startNow)
        #expect(StartReach.decision(fix: farAndOld, routeStart: Self.raleigh, now: now) == .startNow)
    }

    @Test func noFixOrNoRouteStartJustStarts() {
        let now = Date()
        let fix = CLLocation(coordinate: Self.durham, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                             timestamp: now)
        #expect(StartReach.decision(fix: nil, routeStart: Self.raleigh, now: now) == .startNow)
        #expect(StartReach.decision(fix: fix, routeStart: nil, now: now) == .startNow)
    }

    @Test func aRecentFixNearTheStartJustStarts() {
        let now = Date()
        #expect(StartReach.decision(fix: Self.fix(secondsAgo: 5, now: now), routeStart: Self.raleigh, now: now) == .startNow)
    }
}
