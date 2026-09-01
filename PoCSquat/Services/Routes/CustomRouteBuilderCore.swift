import SwiftUI
import Combine
import MapKit
import CoreLocation

// MARK: - Builder State

@MainActor
final class CustomRouteBuilder: ObservableObject {
    @Published var waypoints:    [CLLocationCoordinate2D] = []
    @Published var routeLegs:    [MKRoute] = []
    @Published var loopLeg:      MKRoute?
    @Published var isComputing   = false
    @Published var isLoopClosed  = false
    @Published var activityMode: ActivityMode = .walking

    init(initialWaypoints: [CLLocationCoordinate2D] = [], initialActivityMode: ActivityMode = .walking) {
        self.waypoints    = initialWaypoints
        self.activityMode = initialActivityMode
    }

    var totalDistance: Double {
        let base = routeLegs.reduce(0) { $0 + $1.distance }
        return isLoopClosed ? base + (loopLeg?.distance ?? 0) : base
    }

    var allLegs: [MKRoute] {
        isLoopClosed ? routeLegs + [loopLeg].compactMap { $0 } : routeLegs
    }

    var canSave: Bool { waypoints.count >= 2 && routeLegs.count == waypoints.count - 1 && !isComputing }

    func addWaypoint(_ coord: CLLocationCoordinate2D) {
        waypoints.append(coord)
        Task { await computeLastLeg() }
    }

    func undoLast() {
        if isLoopClosed { isLoopClosed = false; loopLeg = nil; return }
        guard !waypoints.isEmpty else { return }
        waypoints.removeLast()
        if !routeLegs.isEmpty { routeLegs.removeLast() }
    }

    func toggleLoop() {
        if isLoopClosed {
            isLoopClosed = false; loopLeg = nil
        } else {
            Task { await computeLoopLeg() }
        }
    }

    func build(name: String) -> CustomRoute {
        CustomRoute(
            id:            UUID(),
            name:          name.trimmingCharacters(in: .whitespaces).isEmpty ? "My Route" : name,
            waypoints:     waypoints.map { WaypointCoord($0) },
            totalDistance: totalDistance,
            isLoop:        isLoopClosed,
            createdAt:     Date(),
            activityMode:  activityMode
        )
    }

    func computeAllLegs(closedLoop: Bool = false) async {
        guard waypoints.count >= 2 else { return }
        isComputing = true
        defer { isComputing = false }
        routeLegs = []
        loopLeg   = nil
        isLoopClosed = false
        for i in 0..<(waypoints.count - 1) {
            if let leg = await routeLeg(from: waypoints[i], to: waypoints[i + 1]) {
                routeLegs.append(leg)
            }
        }
        if closedLoop, waypoints.count >= 2,
           let leg = await routeLeg(from: waypoints[waypoints.count - 1], to: waypoints[0]) {
            loopLeg      = leg
            isLoopClosed = true
        }
    }

    func recomputeAllLegs() async {
        guard waypoints.count >= 2 else { return }
        let wasLoop = isLoopClosed
        await computeAllLegs(closedLoop: wasLoop)
    }

    private func computeLastLeg() async {
        let n = waypoints.count
        guard n >= 2 else { return }
        isComputing = true
        defer { isComputing = false }

        guard let leg = await routeLeg(from: waypoints[n - 2], to: waypoints[n - 1]) else {
            if waypoints.count == n { waypoints.removeLast() }
            return
        }
        routeLegs.append(leg)
    }

    private func computeLoopLeg() async {
        guard let first = waypoints.first, let last = waypoints.last, waypoints.count >= 2 else { return }
        isComputing = true
        defer { isComputing = false }

        if let leg = await routeLeg(from: last, to: first) {
            loopLeg       = leg
            isLoopClosed  = true
        }
    }

    private func routeLeg(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> MKRoute? {
        let req           = MKDirections.Request()
        req.source        = MKMapItem(location: CLLocation(latitude: from.latitude, longitude: from.longitude), address: nil)
        req.destination   = MKMapItem(location: CLLocation(latitude: to.latitude, longitude: to.longitude), address: nil)
        req.transportType = activityMode.transportType
        return try? await MKDirections(request: req).calculate().routes.first
    }
}

// MARK: - Shared Map UIViewRepresentable

/// Used for both route building (onTap provided) and display (onTap nil).
struct CustomRouteMapView: UIViewRepresentable {
    let waypoints:  [CLLocationCoordinate2D]
    let routeLegs:  [MKRoute]
    var onTap:      ((CLLocationCoordinate2D) -> Void)? = nil

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate           = context.coordinator
        map.showsUserLocation  = true
        map.overrideUserInterfaceStyle = .unspecified

        if onTap != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handleTap(_:)))
            tap.delegate = context.coordinator
            map.addGestureRecognizer(tap)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onTap = onTap

        // Refresh annotations
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
        for (i, wp) in waypoints.enumerated() {
            let ann       = MKPointAnnotation()
            ann.coordinate = wp
            ann.title      = "\(i + 1)"
            map.addAnnotation(ann)
        }

        // Refresh overlays
        map.removeOverlays(map.overlays)
        for leg in routeLegs { map.addOverlay(leg.polyline) }

        let coord = context.coordinator

        // Builder mode: zoom to neighbourhood when first waypoint placed
        if onTap != nil && waypoints.count == 1 && coord.lastWaypointCount == 0 {
            let region = MKCoordinateRegion(center: waypoints[0],
                                            latitudinalMeters: 1_500, longitudinalMeters: 1_500)
            map.setRegion(region, animated: true)
        }

        // Display mode: zoom to fit all content once legs load
        if onTap == nil && routeLegs.count > coord.lastLegCount && !waypoints.isEmpty {
            let rect = waypoints.reduce(MKMapRect.null) { r, c in
                let p = MKMapPoint(c)
                return r.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
            }
            if !rect.isNull {
                map.setVisibleMapRect(rect,
                                      edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40),
                                      animated: true)
            }
        }

        coord.lastWaypointCount = waypoints.count
        coord.lastLegCount      = routeLegs.count
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var onTap:             ((CLLocationCoordinate2D) -> Void)?
        var lastWaypointCount  = 0
        var lastLegCount       = 0
        private var hasZoomedToUser = false

        init(onTap: ((CLLocationCoordinate2D) -> Void)?) { self.onTap = onTap }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let map = gesture.view as? MKMapView else { return }
            let pt = gesture.location(in: map)
            onTap?(map.convert(pt, toCoordinateFrom: map))
        }

        // Ignore taps on existing annotation pins
        func gestureRecognizer(_ gr: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            !(touch.view is MKAnnotationView)
        }

        // Auto-center on user location the first time it's available in builder mode
        func mapView(_ map: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !hasZoomedToUser, onTap != nil, let loc = userLocation.location else { return }
            hasZoomedToUser = true
            let region = MKCoordinateRegion(center: loc.coordinate,
                                            latitudinalMeters: 2_000, longitudinalMeters: 2_000)
            map.setRegion(region, animated: false)
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let pl = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r         = MKPolylineRenderer(polyline: pl)
            r.strokeColor = .brandGreen
            r.lineWidth   = 4
            r.alpha       = 0.9
            return r
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let ann = annotation as? MKPointAnnotation else { return nil }
            let view = MKMarkerAnnotationView(annotation: ann, reuseIdentifier: "waypoint")
            view.glyphText      = ann.title ?? ""
            view.markerTintColor = .brandGreenFill
            view.canShowCallout  = false
            return view
        }
    }
}
