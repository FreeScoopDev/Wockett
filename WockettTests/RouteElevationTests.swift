import Testing
import Foundation
import MapKit
@testable import PoCSquat

/// Heights on the Routes screens follow the distance unit
/// (spec fix/route-units-empty-states). `metric:` is passed explicitly, so
/// the machine's region never decides a result. 1 ft = 0.3048 m.
struct RouteElevationTests {

    @Test func text_roundsToWholeMetresOrFeet() {
        #expect(RouteElevation.text(120.4, metric: true) == "120 m")
        #expect(RouteElevation.text(120.4, metric: false) == "395 ft")   // 395.01
        #expect(RouteElevation.text(98.6, metric: true) == "99 m")       // nearest, not Int() truncation
        #expect(RouteElevation.text(98.6, metric: false) == "323 ft")    // 323.49
        #expect(RouteElevation.text(310, metric: true) == "310 m")
        #expect(RouteElevation.text(310, metric: false) == "\(1017.formatted()) ft")  // 1017.06
    }

    @Test func gainAndLoss_carryTheSignAndUnit() {
        #expect(RouteElevation.gain(120.4, metric: true) == "+120 m")
        #expect(RouteElevation.gain(120.4, metric: false) == "+395 ft")
        #expect(RouteElevation.loss(98.6, metric: true) == "-99 m")
        #expect(RouteElevation.loss(98.6, metric: false) == "-323 ft")
        #expect(RouteElevation.gain(0, metric: true) == "+0 m")
        #expect(RouteElevation.gain(0, metric: false) == "+0 ft")
    }

    @Test func axis_unitAndValue() {
        #expect(RouteElevation.axisUnit(metric: true) == "m")
        #expect(RouteElevation.axisUnit(metric: false) == "ft")
        #expect(RouteElevation.axisValue(120.4, metric: true) == 120.4)
        #expect(abs(RouteElevation.axisValue(120.4, metric: false) - 395.013) < 0.001)
    }

    /// Padded in metres, then converted: the same shape in either unit.
    @Test func axisDomain_padsInMetresThenConverts() {
        let wide = RouteElevation.axisDomain(min: 100, max: 200, metric: true)
        #expect(wide == 70...230)
        let wideFeet = RouteElevation.axisDomain(min: 100, max: 200, metric: false)
        #expect(abs(wideFeet.lowerBound - 229.659) < 0.001)
        #expect(abs(wideFeet.upperBound - 754.593) < 0.001)
        // A flat route: the pad floors at 15 m.
        let flat = RouteElevation.axisDomain(min: 100, max: 105, metric: true)
        #expect(flat == 85...120)
        let flatFeet = RouteElevation.axisDomain(min: 100, max: 105, metric: false)
        #expect(abs(flatFeet.lowerBound - 278.871) < 0.001)
        #expect(abs(flatFeet.upperBound - 393.701) < 0.001)
    }

    /// The rule `RouteElevation.defaultMetric` reads. That each Routes
    /// surface calls the default is read in source, not tested.
    @Test func defaultUnit_followsTheDistanceRule() {
        #expect(WalkAudioCueService.usesMiles(in: Locale(identifier: "en_US")))
        #expect(!WalkAudioCueService.usesMiles(in: Locale(identifier: "en_GB")))
        #expect(!WalkAudioCueService.usesMiles(in: Locale(identifier: "en_CA")))
        // Not a restatement: on a US simulator it fails if the default is
        // hard-wired to metres, on a metric one if hard-wired to feet.
        #expect(RouteElevation.defaultMetric == !WalkAudioCueService.usesMiles(in: .current))
    }

    /// The result cards say the same as the chart. `MKDistanceFormatter`,
    /// which they used before, said "130 yd" for 120 m in en_GB and
    /// "400 ft" in en_US (run on macOS, 2026-11-05).
    @Test func resultCard_usesTheChartsUnit() {
        let card = route(gain: 120.4, loss: 98.6)
        #expect(card.elevationSummary(metric: true) == "↑ 120 m · ↓ 99 m")
        #expect(card.elevationSummary(metric: false) == "↑ 395 ft · ↓ 323 ft")
        #expect(route(gain: 0, loss: 0).elevationSummary(metric: true) == nil)
    }

    /// The card's distance follows the same rule, not the region: before,
    /// `MKDistanceFormatter`'s default said miles on a UK device.
    @Test func resultCard_distanceUsesTheAppsUnit() {
        let card = route(gain: 0, loss: 0)  // 280 m
        #expect(card.distanceText(metric: true).hasSuffix(" m"))
        #expect(card.distanceText(metric: false).hasSuffix(" ft"))
        #expect(card.distanceText(metric: true) != card.distanceText(metric: false))
        #expect(card.distanceText == card.distanceText(metric: RouteElevation.defaultMetric))
    }

    private func route(gain: Double, loss: Double) -> SuggestedRoute {
        var coords = [CLLocationCoordinate2D(latitude: 35.7779, longitude: -78.6387),
                      CLLocationCoordinate2D(latitude: 35.7804, longitude: -78.6387)]
        return SuggestedRoute(
            polyline: MKPolyline(coordinates: &coords, count: coords.count),
            openInMapsItem: MKMapItem.forCurrentLocation(),
            isLoop: false, bearing: 0, totalDistance: 280, totalTime: 200, lapCount: 1,
            label: nil, legWaypoints: coords,
            elevationGainMeters: gain, elevationLossMeters: loss)
    }
}

/// Route History's empty screen says why it is empty.
struct RouteHistoryEmptyTests {

    @Test func nothingFinished_saysSo() {
        #expect(RouteHistoryEmpty.message(noun: "walk", routeName: "Capitol Loop", hidden: 0)
                == "No walks finished on \"Capitol Loop\" yet. Finish one and it appears here.")
        #expect(RouteHistoryEmpty.message(noun: "ride", routeName: "River", hidden: 0)
                == "No rides finished on \"River\" yet. Finish one and it appears here.")
    }

    @Test func leftOut_saysHowManyAndWhy() {
        #expect(RouteHistoryEmpty.message(noun: "walk", routeName: "Capitol Loop", hidden: 1)
                == "1 finished activity on \"Capitol Loop\" is left out of route history "
                + "(not counted in route stats, or it looked like a trip in a vehicle).")
        #expect(RouteHistoryEmpty.message(noun: "walk", routeName: "Capitol Loop", hidden: 3)
                == "3 finished activities on \"Capitol Loop\" are left out of route history "
                + "(not counted in route stats, or they looked like a trip in a vehicle).")
        // The route's noun never names what was left out: it may be a run on a walking route.
        #expect(!RouteHistoryEmpty.message(noun: "walk", routeName: "River", hidden: 1).contains("walk"))
        #expect(!RouteHistoryEmpty.message(noun: "ride", routeName: "River", hidden: 3).contains("ride"))
    }
}

/// Which of a route's sessions Route History shows, and how many it leaves out.
struct RouteHistorySplitTests {

    private let routeID = UUID()

    private func session(route: UUID?, daysAgo: Double, counts: Bool = true, vehicle: Bool = false) -> WalkSession {
        var s = WalkSession(id: UUID(), routeName: "R", date: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400),
                            elapsedTime: 600, totalDistance: 800, waypoints: [], lapCount: 1, isLoop: false)
        s.customRouteId = route
        s.countsTowardRouteStats = counts
        s.flaggedPossibleVehicle = vehicle
        return s
    }

    @Test func excludedAndVehicle_areHiddenAndCounted() {
        let kept = session(route: routeID, daysAgo: 2)
        let newer = session(route: routeID, daysAgo: 1)
        let all = [kept, session(route: routeID, daysAgo: 3, counts: false),
                   session(route: routeID, daysAgo: 4, vehicle: true),
                   newer, session(route: UUID(), daysAgo: 1), session(route: nil, daysAgo: 1)]
        let split = RouteHistoryEmpty.split(all, route: routeID)
        #expect(split.shown.map(\.id) == [newer.id, kept.id])
        #expect(split.hidden == 2)
    }

    /// The screen's text comes from the route's own sessions.
    @Test func emptyScreenText_countsTheRoutesLeftOutSessions() {
        let route = CustomRoute(id: routeID, name: "Loop", waypoints: [], totalDistance: 800, isLoop: true,
                                createdAt: Date(timeIntervalSince1970: 1_800_000_000), activityMode: .cycling)
        let none = RouteHistoryEmpty.text(for: route, sessions: [session(route: UUID(), daysAgo: 1, counts: false)])
        #expect(none.title == "No rides yet")
        #expect(none.message == RouteHistoryEmpty.message(noun: "ride", routeName: "Loop", hidden: 0))
        let two = RouteHistoryEmpty.text(for: route, sessions: [session(route: routeID, daysAgo: 1, counts: false),
                                                                 session(route: routeID, daysAgo: 2, vehicle: true)])
        #expect(two.title == "Nothing in route history")
        #expect(two.message == RouteHistoryEmpty.message(noun: "ride", routeName: "Loop", hidden: 2))
    }

    @Test func noSessions_hidesNone() {
        let split = RouteHistoryEmpty.split([session(route: nil, daysAgo: 1)], route: routeID)
        #expect(split.shown.isEmpty)
        #expect(split.hidden == 0)
    }
}
