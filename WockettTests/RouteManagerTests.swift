import Testing
import Foundation
import MapKit
import CoreLocation
@testable import PoCSquat

struct RouteManagerTests {

    // MARK: - Helpers

    private func route(
        bearing: Double,
        distance: Double,
        time: TimeInterval,
        laps: Int = 1,
        label: String? = nil
    ) -> SuggestedRoute {
        let coord = CLLocationCoordinate2D(latitude: 37.77, longitude: -122.43)
        var coords = [CLLocationCoordinate2D]()
        return SuggestedRoute(
            polyline:       MKPolyline(coordinates: &coords, count: 0),
            openInMapsItem: MKMapItem(placemark: MKPlacemark(coordinate: coord)),
            isLoop:         true,
            bearing:        bearing,
            totalDistance:  distance,
            totalTime:      time,
            lapCount:       laps,
            label:          label,
            legWaypoints:   [coord]
        )
    }

    // MARK: - Direction names

    @Test func directionName_north_atZeroDegrees() {
        #expect(route(bearing: 0, distance: 1_000, time: 600).directionName == "North")
    }

    @Test func directionName_east_atNinetyDegrees() {
        #expect(route(bearing: 90, distance: 1_000, time: 600).directionName == "East")
    }

    @Test func directionName_south_at180() {
        #expect(route(bearing: 180, distance: 1_000, time: 600).directionName == "South")
    }

    @Test func directionName_west_at270() {
        #expect(route(bearing: 270, distance: 1_000, time: 600).directionName == "West")
    }

    @Test func directionName_north_at359Degrees() {
        // Bearing wraps around: 337.5–360 is North
        #expect(route(bearing: 359, distance: 1_000, time: 600).directionName == "North")
    }

    @Test func directionName_northeast_at45Degrees() {
        #expect(route(bearing: 45, distance: 1_000, time: 600).directionName == "Northeast")
    }

    // MARK: - Time text

    @Test func timeText_formatsMinutesUnderAnHour() {
        #expect(route(bearing: 0, distance: 1_000, time: 25 * 60).timeText == "25 min")
    }

    @Test func timeText_formatsHoursAndMinutesOverAnHour() {
        #expect(route(bearing: 0, distance: 5_000, time: 90 * 60).timeText == "1h 30m")
    }

    @Test func timeText_exactlyOneHour() {
        #expect(route(bearing: 0, distance: 5_000, time: 60 * 60).timeText == "1h 0m")
    }

    // MARK: - Estimated steps

    @Test func estimatedSteps_derivedFromDistanceDividedByStrideLength() {
        // 762 m / 0.762 m per step = 1 000 steps
        let r = route(bearing: 0, distance: 762, time: 500)
        #expect(r.estimatedSteps == 1_000)
    }

    // MARK: - Distance text (multi-lap)

    @Test func distanceText_singleLap_doesNotContainMultiplier() {
        let r = route(bearing: 0, distance: 2_000, time: 1_200, laps: 1)
        #expect(!r.distanceText.contains("×"))
    }

    @Test func distanceText_multiLap_containsLapMultiplier() {
        let r = route(bearing: 0, distance: 2_000, time: 1_200, laps: 2)
        #expect(r.distanceText.contains("× 2"))
    }

    // MARK: - Palette color

    @Test func paletteColor_deterministicForSameInputs() {
        let c1 = SuggestedRoute.paletteColor(index: 0, total: 4)
        let c2 = SuggestedRoute.paletteColor(index: 0, total: 4)
        #expect(c1 == c2)
    }

    @Test func paletteColor_differsAcrossIndices() {
        let c0 = SuggestedRoute.paletteColor(index: 0, total: 4)
        let c1 = SuggestedRoute.paletteColor(index: 1, total: 4)
        #expect(c0 != c1)
    }

    // MARK: - Coordinate offset geometry

    @Test func coordinateOffset_displacesByExpectedDistance() {
        let origin     = CLLocationCoordinate2D(latitude: 37.77, longitude: -122.43)
        let displaced  = origin.offset(bearing: 0, meters: 1_000)
        let originLoc  = CLLocation(latitude: origin.latitude,    longitude: origin.longitude)
        let resultLoc  = CLLocation(latitude: displaced.latitude, longitude: displaced.longitude)
        let actualDist = originLoc.distance(from: resultLoc)
        // Allow ±3 m for floating-point and spherical approximation differences
        #expect(abs(actualDist - 1_000) < 3.0)
    }

    @Test func coordinateOffset_zeroDist_returnsOriginalCoordinate() {
        let origin    = CLLocationCoordinate2D(latitude: 37.77, longitude: -122.43)
        let displaced = origin.offset(bearing: 0, meters: 0)
        #expect(abs(displaced.latitude  - origin.latitude)  < 1e-9)
        #expect(abs(displaced.longitude - origin.longitude) < 1e-9)
    }

    // MARK: - Chosen starting place (spec fix/route-start-place)

    private static let fixed = CLLocation(latitude: 40.0, longitude: -75.0)
    private static var place: MKMapItem {
        let item = MKMapItem(location: CLLocation(latitude: 35.7796, longitude: -78.6382), address: nil)
        item.name = "Pullen Park"
        return item
    }

    @Test @MainActor func planningOrigin_prefersTheChosenPlace_andIsNotLive() async throws {
        let manager = RouteManager(fixedLocation: Self.fixed)
        manager.choose(Self.place)
        let origin = try #require(await manager.planningOrigin())
        #expect(origin.location.coordinate.latitude == 35.7796)
        #expect(origin.location.coordinate.longitude == -78.6382)
        #expect(!origin.isLive)
    }

    /// Community "near you" and trail directions read lastLocation.
    @Test @MainActor func recordOrigin_neverWritesAChosenPlaceIntoLastLocation() async throws {
        let manager = RouteManager(fixedLocation: Self.fixed)
        manager.lastLocation = Self.fixed
        manager.choose(Self.place)
        manager.recordOrigin(try #require(await manager.planningOrigin()))
        #expect(manager.lastLocation?.coordinate.latitude == 40.0)
    }

    @Test @MainActor func withNoChosenPlace_theLiveLocationIsUsedAndRecorded() async throws {
        let manager = RouteManager(fixedLocation: Self.fixed)
        let origin = try #require(await manager.planningOrigin())
        #expect(origin.isLive)
        #expect(origin.location.coordinate.latitude == 40.0)
        manager.recordOrigin(origin)
        #expect(manager.lastLocation?.coordinate.latitude == 40.0)
    }

    /// The results panel's weather must not claim to be where the person is
    /// when it was fetched at a chosen place (spec fix/route-start-place).
    @Test @MainActor func weatherLabelNamesTheChosenPlace() {
        let manager = RouteManager(fixedLocation: Self.fixed)
        #expect(manager.weatherPlaceLabel == "Where you are")
        let item = MKMapItem(location: CLLocation(latitude: 35.78, longitude: -78.64), address: nil)
        item.name = "Pullen Park"
        manager.choose(item)
        #expect(manager.weatherPlaceLabel == "Near Pullen Park")
        manager.useMyLocation()
        #expect(manager.weatherPlaceLabel == "Where you are")
    }

    @Test @MainActor func useMyLocation_clearsTheChosenPlace() async throws {
        let manager = RouteManager(fixedLocation: Self.fixed)
        manager.choose(Self.place)
        #expect(manager.chosenStart?.name == "Pullen Park")
        #expect(manager.locationState == .chosen(over: .live))
        manager.useMyLocation()
        #expect(manager.chosenStart == nil)
        #expect(manager.locationState == .live)
        #expect(try #require(await manager.planningOrigin()).isLive)
    }

    // MARK: - Location waiters (fix/route-start-follow-ups)

    /// Routes opening and Start's check can both wait on one location request.
    /// Before, the second answered the first with nil, so the first could not
    /// tell being overtaken from a real failure.
    @Test @MainActor func overlappingWaiters_allGetTheSameFix() {
        var waiters = LocationWaiters<Int?>()
        var first: Int?? = .none
        var second: Int?? = .none
        #expect(waiters.add { first = $0 }, "the first waiter asks CoreLocation")
        #expect(!waiters.add { second = $0 }, "a later waiter shares the request in flight")
        #expect(first == .none, "nobody is answered before the request is")
        waiters.answerAll(7)
        #expect(first == .some(7))
        #expect(second == .some(7))
    }

    @Test @MainActor func aFailedRequest_answersEveryWaiterNil() {
        var waiters = LocationWaiters<Int?>()
        var answers: [Int?] = []
        _ = waiters.add { answers.append($0) }
        _ = waiters.add { answers.append($0) }
        waiters.answerAll(nil)
        #expect(answers == [nil, nil])
    }

    /// Each continuation is resumed exactly once: a second answer (CoreLocation
    /// can deliver more than one update) reaches nobody, and the next caller
    /// starts a request of its own.
    @Test @MainActor func answeredWaiters_areNotAnsweredAgain() {
        var waiters = LocationWaiters<Int?>()
        var calls = 0
        _ = waiters.add { _ in calls += 1 }
        _ = waiters.add { _ in calls += 1 }
        waiters.answerAll(1)
        waiters.answerAll(2)
        #expect(calls == 2, "two waiters, each answered once")
        #expect(waiters.add { _ in }, "after an answer, the next waiter asks again")
    }
}
