import SwiftUI
import Combine
import MapKit
import CoreLocation

// MARK: - Directions Throttler

// Apple's Maps daemon (geod) throttles apps that exceed ~50 MKDirections requests
// per 10 seconds. This actor serialises every calculate() call through a reservation
// queue: each caller claims a future time slot, then sleeps until that slot arrives.
// Result: at most ~4.5 requests/second (45/10s) regardless of concurrency.
// Swift task cancellation propagates correctly — sleeping tasks throw CancellationError.
private actor DirectionsThrottler {
    static let shared = DirectionsThrottler()
    private init() {}

    private var nextSlot: Date = .distantPast
    private let spacing: TimeInterval = 0.30  // ~3.3 req/s = 33/10s

    func calculate(_ request: MKDirections.Request) async throws -> MKDirections.Response {
        let slot = max(nextSlot, Date())
        nextSlot = slot.addingTimeInterval(spacing)
        let wait = slot.timeIntervalSinceNow
        if wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        return try await MKDirections(request: request).calculate()
    }

    // Call at the start of each new search so in-flight cancellations don't
    // leave reserved slots that delay the next generation cycle.
    func reset() { nextSlot = .distantPast }
}

// MARK: - Route Manager

@MainActor
final class RouteManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var suggestedRoutes: [SuggestedRoute] = []
    @Published var isGenerating   = false
    @Published var locationError: String?
    @Published var authStatus: CLAuthorizationStatus = .notDetermined
    @Published var lastLocation: CLLocation?

    private let locationManager = CLLocationManager()
    nonisolated(unsafe) private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    // Monotonically-increasing token: each new search increments this so stale
    // tasks from a cancelled search can't overwrite isGenerating or suggestedRoutes.
    private var searchGeneration = 0

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authStatus = locationManager.authorizationStatus
    }

    // MARK: - Public

    func generateRoutes(remainingMeters: Double,
                        transportType: MKDirectionsTransportType = .walking) async {
        searchGeneration += 1
        let myGen = searchGeneration
        isGenerating    = true
        locationError   = nil
        suggestedRoutes = []
        await DirectionsThrottler.shared.reset()
        // Only set isGenerating = false if no newer search has already taken over.
        defer { if searchGeneration == myGen { isGenerating = false } }

        guard let location = await currentLocation() else {
            locationError = "Unable to get your location. Check that location permission is granted."
            return
        }
        lastLocation = location

        // Apply +12% buffer so routes slightly exceed the remaining goal.
        let targetMeters = remainingMeters * 1.12

        var routes = await generateLoopRoutes(from: location, targetMeters: targetMeters,
                                              transportType: transportType)

        // Fallback: try all 4 bearings with conservative leg sizes so results are never empty.
        if routes.isEmpty {
            routes.append(contentsOf: await makeFallbackRoutes(from: location,
                                                               targetMeters: targetMeters,
                                                               transportType: transportType))
        }

        // Bail if a newer search has started or this task was cancelled.
        guard searchGeneration == myGen, !Task.isCancelled else { return }
        suggestedRoutes = routes.enumerated().map { i, r in
            var r = r; r.colorIndex = i; return r
        }
        if suggestedRoutes.isEmpty {
            locationError = "No routes found here. Try a different duration."
        }
    }

    /// Generates tight neighborhood loops close to home. Called when the primary search finds nothing.
    func generateNearbyLoops(remainingMeters: Double,
                              transportType: MKDirectionsTransportType = .walking) async {
        searchGeneration += 1
        let myGen = searchGeneration
        isGenerating    = true
        locationError   = nil
        suggestedRoutes = []
        await DirectionsThrottler.shared.reset()
        defer { if searchGeneration == myGen { isGenerating = false } }

        guard let location = await currentLocation() else {
            locationError = "Unable to get your location. Check that location permission is granted."
            return
        }
        lastLocation = location

        let targetMeters = remainingMeters * 1.12
        // Tight legs so the loop stays close to home regardless of overall goal distance.
        let legDist = (targetMeters / 4.0).clamped(to: 120.0...400.0)

        var routes: [SuggestedRoute] = []
        // Same rate-limit mitigation as generateLoopRoutes: run 2 at a time.
        let nearbyBearings: [Double] = [0.0, 90.0, 180.0, 270.0]
        await withTaskGroup(of: SuggestedRoute?.self) { group in
            var idx = 0
            while idx < 2 && idx < nearbyBearings.count {
                let b = nearbyBearings[idx]
                group.addTask {
                    await self.makeNearbyLoopRoute(from: location, bearing: b,
                                                   targetMeters: targetMeters, legDist: legDist,
                                                   transportType: transportType)
                }
                idx += 1
            }
            for await result in group {
                if let r = result { routes.append(r) }
                if idx < nearbyBearings.count {
                    let b = nearbyBearings[idx]
                    group.addTask {
                        await self.makeNearbyLoopRoute(from: location, bearing: b,
                                                       targetMeters: targetMeters, legDist: legDist,
                                                       transportType: transportType)
                    }
                    idx += 1
                }
            }
        }
        routes.sort { $0.bearing < $1.bearing }

        if routes.isEmpty {
            routes.append(contentsOf: await makeFallbackRoutes(from: location,
                                                               targetMeters: targetMeters,
                                                               transportType: transportType))
        }

        guard searchGeneration == myGen, !Task.isCancelled else { return }
        suggestedRoutes = routes.enumerated().map { i, r in var r = r; r.colorIndex = i; return r }
        if suggestedRoutes.isEmpty {
            locationError = "No routes found nearby. Try a different duration."
        }
    }

    /// Small loop sized to radius; no quality ratio filter since multi-lap backtracking is expected.
    private func makeNearbyLoopRoute(from start: CLLocation, bearing: Double,
                                      targetMeters: Double, legDist: Double,
                                      transportType: MKDirectionsTransportType) async -> SuggestedRoute? {
        let coordA = start.coordinate.offset(bearing: bearing,       meters: legDist)
        let coordB = coordA.offset(          bearing: bearing + 90,  meters: legDist)
        let coordC = coordB.offset(          bearing: bearing + 180, meters: legDist)

        guard let leg1 = await route(from: start.coordinate, to: coordA, transportType: transportType),
              let leg2 = await route(from: coordA,            to: coordB, transportType: transportType),
              let leg3 = await route(from: coordB,            to: coordC, transportType: transportType),
              let leg4 = await route(from: coordC,            to: start.coordinate, transportType: transportType) else { return nil }

        let perLapDist = leg1.distance + leg2.distance + leg3.distance + leg4.distance
        let perLapTime = leg1.expectedTravelTime + leg2.expectedTravelTime + leg3.expectedTravelTime + leg4.expectedTravelTime
        guard perLapDist > 50 else { return nil }

        let laps = max(1, min(8, Int(ceil(targetMeters / max(perLapDist, 1)))))

        return SuggestedRoute(
            polyline:            combinePolylines([leg1.polyline, leg2.polyline, leg3.polyline, leg4.polyline]),
            openInMapsItem:      MKMapItem(location: coordA.clLocation, address: nil),
            isLoop:              true,
            bearing:             bearing,
            totalDistance:       perLapDist * Double(laps),
            totalTime:           perLapTime * Double(laps),
            lapCount:            laps,
            label:               nil,
            legWaypoints:        [start.coordinate, coordA, coordB, coordC],
            elevationGainMeters: 0,
            elevationLossMeters: 0
        )
    }

    func generateDestinationRoute(to destination: MKMapItem,
                                   transportType: MKDirectionsTransportType = .walking) async {
        isGenerating    = true
        locationError   = nil
        suggestedRoutes = []
        await DirectionsThrottler.shared.reset()
        defer { isGenerating = false }

        guard let location = await currentLocation() else {
            locationError = "Unable to get your location. Check that location permission is granted."
            return
        }
        lastLocation = location

        let destCoord = destination.location.coordinate
        guard let leg = await route(from: location.coordinate, to: destCoord, transportType: transportType) else {
            locationError = "No route found to \(destination.name ?? "that destination")."
            return
        }

        suggestedRoutes = [SuggestedRoute(
            polyline:       leg.polyline,
            openInMapsItem: destination,
            isLoop:         false,
            bearing:        location.coordinate.bearing(to: destCoord),
            totalDistance:  leg.distance,
            totalTime:      leg.expectedTravelTime,
            lapCount:       1,
            label:          destination.name,
            legWaypoints:   [location.coordinate, destCoord]
        )]
    }

    func generateLoopDestinationRoute(to destination: MKMapItem,
                                       transportType: MKDirectionsTransportType = .walking) async {
        isGenerating    = true
        locationError   = nil
        suggestedRoutes = []
        await DirectionsThrottler.shared.reset()
        defer { isGenerating = false }

        guard let location = await currentLocation() else {
            locationError = "Unable to get your location. Check that location permission is granted."
            return
        }
        lastLocation = location

        let destCoord = destination.location.coordinate
        guard let outbound = await route(from: location.coordinate, to: destCoord, transportType: transportType),
              let inbound  = await route(from: destCoord, to: location.coordinate, transportType: transportType) else {
            locationError = "No route found to \(destination.name ?? "that destination")."
            return
        }

        suggestedRoutes = [SuggestedRoute(
            polyline:       combinePolylines([outbound.polyline, inbound.polyline]),
            openInMapsItem: destination,
            isLoop:         true,
            bearing:        location.coordinate.bearing(to: destCoord),
            totalDistance:  outbound.distance + inbound.distance,
            totalTime:      outbound.expectedTravelTime + inbound.expectedTravelTime,
            lapCount:       1,
            label:          "\(destination.name ?? "Destination") & Back",
            legWaypoints:   [location.coordinate, destCoord]
        )]
    }

    func fetchCurrentLocation() async -> CLLocation? {
        await currentLocation()
    }

    // MARK: - Loop Routes

    private func generateLoopRoutes(from start: CLLocation, targetMeters: Double,
                                     transportType: MKDirectionsTransportType) async -> [SuggestedRoute] {
        var routes: [SuggestedRoute] = []
        let idealLegDist = (targetMeters / 4.0).clamped(to: 250.0...2_000.0)

        // Cardinal directions only (N/E/S/W). Diagonals rarely produce meaningfully
        // different routes and double the direction request count. Each bearing gets two
        // attempts: ideal leg distance first, then 30% wider if the first fails geometry
        // checks. Run at most 2 concurrently to limit slot reservation depth.
        let bearings: [Double] = [0.0, 90.0, 180.0, 270.0]
        await withTaskGroup(of: SuggestedRoute?.self) { group in
            var idx = 0
            while idx < 2 && idx < bearings.count {
                let b = bearings[idx]
                group.addTask {
                    if let r = await self.makeLoopRoute(from: start, bearing: b,
                                                        legDist: idealLegDist,
                                                        targetMeters: targetMeters,
                                                        transportType: transportType) { return r }
                    let expanded = min(idealLegDist * 1.3, 2_000.0)
                    return await self.makeLoopRoute(from: start, bearing: b,
                                                   legDist: expanded,
                                                   targetMeters: targetMeters,
                                                   transportType: transportType)
                }
                idx += 1
            }
            for await result in group {
                if let r = result { routes.append(r) }
                if idx < bearings.count {
                    let b = bearings[idx]
                    group.addTask {
                        if let r = await self.makeLoopRoute(from: start, bearing: b,
                                                            legDist: idealLegDist,
                                                            targetMeters: targetMeters,
                                                            transportType: transportType) { return r }
                        let expanded = min(idealLegDist * 1.3, 2_000.0)
                        return await self.makeLoopRoute(from: start, bearing: b,
                                                       legDist: expanded,
                                                       targetMeters: targetMeters,
                                                       transportType: transportType)
                    }
                    idx += 1
                }
            }
        }
        routes.sort { $0.totalDistance < $1.totalDistance }
        return routes
    }

    /// Quadrilateral loop: Start → A → B → C → Start, each leg at 90° to the previous.
    /// legDist is supplied by the caller so the caller can retry with expanded geometry
    /// while keeping targetMeters (the real user goal) consistent for lap calculation.
    ///
    /// Straightness is checked immediately after each leg fetch so we bail as soon as
    /// bad geometry is detected — avoiding 2–3 wasted direction calls on a doomed route.
    private func makeLoopRoute(from start: CLLocation,
                               bearing: Double,
                               legDist: Double,
                               targetMeters: Double,
                               transportType: MKDirectionsTransportType) async -> SuggestedRoute? {
        let coordA = start.coordinate.offset(bearing: bearing,       meters: legDist)
        let coordB = coordA.offset(          bearing: bearing + 90,  meters: legDist)
        let coordC = coordB.offset(          bearing: bearing + 180, meters: legDist)

        guard let leg1 = await route(from: start.coordinate, to: coordA, transportType: transportType),
              leg1.distance <= start.distance(from: coordA.clLocation) * 1.8 else { return nil }
        guard let leg2 = await route(from: coordA, to: coordB, transportType: transportType),
              leg2.distance <= coordA.clLocation.distance(from: coordB.clLocation) * 1.8 else { return nil }
        guard let leg3 = await route(from: coordB, to: coordC, transportType: transportType),
              leg3.distance <= coordB.clLocation.distance(from: coordC.clLocation) * 1.8 else { return nil }
        guard let leg4 = await route(from: coordC, to: start.coordinate, transportType: transportType),
              leg4.distance <= coordC.clLocation.distance(from: start) * 1.8 else { return nil }

        let perLapDist = leg1.distance + leg2.distance + leg3.distance + leg4.distance
        let perLapTime = leg1.expectedTravelTime + leg2.expectedTravelTime + leg3.expectedTravelTime + leg4.expectedTravelTime

        // Overall perimeter sanity check (catches degenerate geometry).
        let geometricPerimeter = legDist * 4.0
        guard perLapDist >= geometricPerimeter * 0.5,
              perLapDist <= geometricPerimeter * 2.5 else { return nil }

        // Laps use the real target, not the (possibly expanded) legDist.
        let laps = max(1, min(2, Int(ceil(targetMeters / max(perLapDist, 1)))))

        return SuggestedRoute(
            polyline:            combinePolylines([leg1.polyline, leg2.polyline, leg3.polyline, leg4.polyline]),
            openInMapsItem:      MKMapItem(location: coordA.clLocation, address: nil),
            isLoop:              true,
            bearing:             bearing,
            totalDistance:       perLapDist * Double(laps),
            totalTime:           perLapTime * Double(laps),
            lapCount:            laps,
            label:               nil,
            legWaypoints:        [start.coordinate, coordA, coordB, coordC],
            elevationGainMeters: 0,
            elevationLossMeters: 0
        )
    }

    // MARK: - Fallback

    /// Tries all 4 cardinal bearings with conservative 250–500m legs so at least one direction succeeds
    /// even near coastlines, rivers, or parks where the primary geometry checks fail.
    private func makeFallbackRoutes(from start: CLLocation, targetMeters: Double,
                                     transportType: MKDirectionsTransportType) async -> [SuggestedRoute] {
        let legDist = (targetMeters / 4.0).clamped(to: 250.0...500.0)
        var results: [SuggestedRoute] = []

        for bearing in [0.0, 90.0, 180.0, 270.0] {
            let coordA = start.coordinate.offset(bearing: bearing,       meters: legDist)
            let coordB = coordA.offset(          bearing: bearing + 90,  meters: legDist)
            let coordC = coordB.offset(          bearing: bearing + 180, meters: legDist)

            guard let leg1 = await route(from: start.coordinate, to: coordA, transportType: transportType),
                  let leg2 = await route(from: coordA,            to: coordB, transportType: transportType),
                  let leg3 = await route(from: coordB,            to: coordC, transportType: transportType),
                  let leg4 = await route(from: coordC,            to: start.coordinate, transportType: transportType)
            else { continue }

            let perLapDist = leg1.distance + leg2.distance + leg3.distance + leg4.distance
            let perLapTime = leg1.expectedTravelTime + leg2.expectedTravelTime + leg3.expectedTravelTime + leg4.expectedTravelTime
            guard perLapDist > 50 else { continue }

            let laps = max(1, min(2, Int(ceil(targetMeters / max(perLapDist, 1)))))
            results.append(SuggestedRoute(
                polyline:       combinePolylines([leg1.polyline, leg2.polyline, leg3.polyline, leg4.polyline]),
                openInMapsItem: MKMapItem(location: coordA.clLocation, address: nil),
                isLoop:         true,
                bearing:        bearing,
                totalDistance:  perLapDist * Double(laps),
                totalTime:      perLapTime * Double(laps),
                lapCount:       laps,
                label:          nil,
                legWaypoints:   [start.coordinate, coordA, coordB, coordC]
            ))
        }
        return results
    }

    // MARK: - Helpers

    private func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                       transportType: MKDirectionsTransportType) async -> MKRoute? {
        let req = MKDirections.Request()
        req.source        = MKMapItem(location: from.clLocation, address: nil)
        req.destination   = MKMapItem(location: to.clLocation,   address: nil)
        req.transportType = transportType
        return try? await DirectionsThrottler.shared.calculate(req).routes.first
    }

    private func combinePolylines(_ polylines: [MKPolyline]) -> MKPolyline {
        var coords: [CLLocationCoordinate2D] = []
        for pl in polylines {
            let pts = pl.points()
            for i in 0..<pl.pointCount { coords.append(pts[i].coordinate) }
        }
        return MKPolyline(coordinates: &coords, count: coords.count)
    }

    // MARK: - Location

    private func currentLocation() async -> CLLocation? {
        if isWKTUITestMode {
            return CLLocation(latitude: 40.7589, longitude: -73.9851)
        }
        if authStatus == .notDetermined { locationManager.requestWhenInUseAuthorization() }
        guard authStatus == .authorizedWhenInUse || authStatus == .authorizedAlways else { return nil }
        if let cached = locationManager.location, -cached.timestamp.timeIntervalSinceNow < 300 { return cached }
        return await withCheckedContinuation { cont in
            locationContinuation = cont
            locationManager.requestLocation()
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        Task { @MainActor in
            locationContinuation?.resume(returning: loc)
            locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            locationContinuation?.resume(returning: nil)
            locationContinuation = nil
            locationError = "Location error: \(error.localizedDescription)"
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in authStatus = manager.authorizationStatus }
    }
}
