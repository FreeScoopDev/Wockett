import SwiftUI
import MapKit

// MARK: - Route Map View

struct RouteMapView: UIViewRepresentable {
    let routes: [SuggestedRoute]
    @Binding var selectedRoute: SuggestedRoute?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.overrideUserInterfaceStyle = .unspecified
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let currentIds = routes.map { $0.id }

        // Only rebuild overlays when the route set itself changes
        if context.coordinator.lastRouteIds != currentIds {
            context.coordinator.lastRouteIds = currentIds
            context.coordinator.lastSelectedId = nil  // reset so renderer update runs below
            map.removeOverlays(map.overlays)
            var coords: [CLLocationCoordinate2D] = []
            for route in routes {
                let pl = route.polyline
                pl.title = route.id.uuidString
                map.addOverlay(pl, level: .aboveRoads)
                let pts = pl.points()
                for i in 0..<pl.pointCount { coords.append(pts[i].coordinate) }
            }
            if let user = map.userLocation.location { coords.append(user.coordinate) }
            if !coords.isEmpty {
                let rect = coords.reduce(MKMapRect.null) { r, c in
                    let p = MKMapPoint(c)
                    return r.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
                map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: false)
            }
        }

        // When selection changes, update renderer properties directly (no flash)
        let newSelectedId = selectedRoute?.id
        if context.coordinator.lastSelectedId != newSelectedId {
            context.coordinator.lastSelectedId = newSelectedId
            let total = routes.count
            let hasSelection = selectedRoute != nil
            for overlay in map.overlays {
                guard let pl = overlay as? MKPolyline,
                      let renderer = map.renderer(for: overlay) as? MKPolylineRenderer,
                      let route = routes.first(where: { $0.id.uuidString == pl.title }) else { continue }
                let isSelected = route.id == newSelectedId
                renderer.strokeColor = SuggestedRoute.paletteUIColor(index: route.colorIndex, total: total)
                renderer.lineWidth = isSelected ? 6 : 3
                renderer.alpha     = isSelected ? 1.0 : (hasSelection ? 0.2 : 0.6)
                renderer.setNeedsDisplay()
            }

            // Zoom to selected route; zoom out to show all when deselected
            if let sel = selectedRoute {
                var rect = MKMapRect.null
                let pts = sel.polyline.points()
                for i in 0..<sel.polyline.pointCount {
                    let p = MKMapPoint(pts[i].coordinate)
                    rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
                if !rect.isNull {
                    map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50), animated: true)
                }
            } else if !routes.isEmpty {
                var coords: [CLLocationCoordinate2D] = []
                for route in routes {
                    let pts = route.polyline.points()
                    for i in 0..<route.polyline.pointCount { coords.append(pts[i].coordinate) }
                }
                let rect = coords.reduce(MKMapRect.null) { r, c in
                    let p = MKMapPoint(c)
                    return r.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
                if !rect.isNull {
                    map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: true)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RouteMapView
        var lastRouteIds: [UUID] = []
        var lastSelectedId: UUID? = UUID()  // non-nil sentinel forces first render
        init(_ p: RouteMapView) { parent = p }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let pl = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: pl)
            let total = parent.routes.count
            let hasSelection = parent.selectedRoute != nil
            if let route = parent.routes.first(where: { $0.id.uuidString == pl.title }) {
                let isSelected = route.id == parent.selectedRoute?.id
                r.strokeColor = SuggestedRoute.paletteUIColor(index: route.colorIndex, total: total)
                r.lineWidth   = isSelected ? 6 : 3
                r.alpha       = isSelected ? 1.0 : (hasSelection ? 0.2 : 0.6)
            }
            return r
        }
    }
}
