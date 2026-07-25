import SwiftUI
import Combine
import MapKit
import CoreLocation

// MARK: - Models

struct WaypointCoord: Codable, Hashable {
    let latitude: Double
    let longitude: Double

    init(_ coord: CLLocationCoordinate2D) {
        latitude  = coord.latitude
        longitude = coord.longitude
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct CustomRoute: Identifiable, Codable {
    let id:            UUID
    var name:          String
    let waypoints:     [WaypointCoord]
    var totalDistance: Double        // metres
    var isLoop:        Bool
    let createdAt:     Date

    var estimatedSteps: Int { Int(totalDistance / 0.762) }

    var distanceText: String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: totalDistance)
    }

    var timeText: String {
        let mins = Int(totalDistance / 1.4 / 60)
        return mins < 60 ? "\(mins) min" : "\(mins / 60)h \(mins % 60)m"
    }

    var centroid: CLLocationCoordinate2D {
        let n   = Double(waypoints.count)
        let lat = waypoints.reduce(0.0) { $0 + $1.latitude }  / n
        let lon = waypoints.reduce(0.0) { $0 + $1.longitude } / n
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

// MARK: - Store

@MainActor
final class CustomRouteStore: ObservableObject {
    @Published var routes: [CustomRoute] = []
    private let udKey = "customRoutes_v1"

    init() { load() }

    func save(_ route: CustomRoute) {
        routes.insert(route, at: 0)
        persist()
    }

    func delete(at offsets: IndexSet) {
        routes.remove(atOffsets: offsets)
        persist()
    }

    func reload() { load() }

    private func persist() {
        if let data = try? JSONEncoder().encode(routes) {
            UserDefaults.standard.set(data, forKey: udKey)
        }
    }

    private func load() {
        guard let data    = UserDefaults.standard.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([CustomRoute].self, from: data) else { return }
        routes = decoded
    }
}

// MARK: - Builder State

@MainActor
final class CustomRouteBuilder: ObservableObject {
    @Published var waypoints:    [CLLocationCoordinate2D] = []
    @Published var routeLegs:    [MKRoute] = []
    @Published var loopLeg:      MKRoute?
    @Published var isComputing   = false
    @Published var isLoopClosed  = false

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
            createdAt:     Date()
        )
    }

    private func computeLastLeg() async {
        let n = waypoints.count
        guard n >= 2 else { return }
        isComputing = true
        defer { isComputing = false }

        guard let leg = await walkingRoute(from: waypoints[n - 2], to: waypoints[n - 1]) else {
            if waypoints.count == n { waypoints.removeLast() }
            return
        }
        routeLegs.append(leg)
    }

    private func computeLoopLeg() async {
        guard let first = waypoints.first, let last = waypoints.last, waypoints.count >= 2 else { return }
        isComputing = true
        defer { isComputing = false }

        if let leg = await walkingRoute(from: last, to: first) {
            loopLeg       = leg
            isLoopClosed  = true
        }
    }

    private func walkingRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> MKRoute? {
        let req           = MKDirections.Request()
        req.source        = MKMapItem(placemark: MKPlacemark(coordinate: from))
        req.destination   = MKMapItem(placemark: MKPlacemark(coordinate: to))
        req.transportType = .walking
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
            view.markerTintColor = .brandGreen
            view.canShowCallout  = false
            return view
        }
    }
}

// MARK: - Route Builder View

struct CustomRouteBuilderView: View {
    @StateObject private var builder = CustomRouteBuilder()
    @State private var showSaveSheet = false
    @State private var routeName     = ""
    @Environment(\.dismiss) private var dismiss
    let onSave: (CustomRoute) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            CustomRouteMapView(
                waypoints: builder.waypoints,
                routeLegs: builder.allLegs,
                onTap:     { builder.addWaypoint($0) }
            )
            .ignoresSafeArea()

            // Empty-state hint
            if builder.waypoints.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 34)).foregroundColor(.earthGreen)
                    Text("Tap the map to add waypoints")
                        .font(.headline).foregroundColor(.earthCream)
                    Text("MapKit finds walking routes between each point")
                        .font(.subheadline).foregroundColor(.earthMuted)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                .padding(.bottom, 160)
            }

            // Bottom control panel
            VStack(spacing: 12) {
                if !builder.waypoints.isEmpty {
                    HStack(spacing: 0) {
                        statChip(value: "\(builder.waypoints.count)", label: "points")
                        Divider()
                            .frame(height: 30)
                            .background(Color.earthMuted.opacity(0.3))
                            .padding(.horizontal, 12)
                        statChip(value: distanceText(builder.totalDistance), label: "distance")
                        if builder.isComputing {
                            Divider()
                                .frame(height: 30)
                                .background(Color.earthMuted.opacity(0.3))
                                .padding(.horizontal, 12)
                            ProgressView().tint(.earthGreen).scaleEffect(0.85)
                        }
                        Spacer()
                        if builder.waypoints.count >= 2 && !builder.isComputing {
                            Toggle(isOn: Binding(get: { builder.isLoopClosed },
                                                 set: { _ in builder.toggleLoop() })) {
                                Text("Loop").font(.subheadline.bold()).foregroundColor(.earthCream)
                            }
                            .tint(.earthGreen).fixedSize()
                        }
                    }
                    .padding(.horizontal)
                }

                HStack(spacing: 10) {
                    if !builder.waypoints.isEmpty {
                        Button { builder.undoLast() } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(Color.earthCard)
                                .foregroundColor(.earthCream)
                                .cornerRadius(12)
                        }
                    }
                    if builder.canSave {
                        Button { showSaveSheet = true } label: {
                            Text("Save Route")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(Color.earthOrange)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
        }
        .navigationTitle("Build Route")
        .navigationBarTitleDisplayMode(.inline)        .sheet(isPresented: $showSaveSheet) {
            SaveRouteSheet(routeName: $routeName) {
                let route = builder.build(name: routeName)
                onSave(route)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func statChip(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).foregroundColor(.earthCream)
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
    }

    private func distanceText(_ m: Double) -> String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: m)
    }
}

// MARK: - Save Sheet

struct SaveRouteSheet: View {
    @Binding var routeName: String
    @Environment(\.dismiss) private var dismiss
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 52)).foregroundColor(.earthGreen)
                    Text("Name your route")
                        .font(.subheadline).foregroundColor(.earthMuted)
                    TextField("e.g. Morning Loop", text: $routeName)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .foregroundColor(.earthCream)
                        .padding()
                        .background(Color.earthCard)
                        .cornerRadius(12)
                    Spacer()
                }
                .padding(32)
            }
            .navigationTitle("Save Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave() }.foregroundColor(.earthGreen)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.earthMuted)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - My Routes List

struct CustomRoutesListView: View {
    @ObservedObject var store:        CustomRouteStore
    @ObservedObject var historyStore: WalkHistoryStore
    @State private var isBuilding = false

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            Group {
                if store.routes.isEmpty { emptyState } else { routeList }
            }
        }
        .navigationTitle("My Routes")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.reload() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { isBuilding = true } label: {
                    Image(systemName: "plus").foregroundColor(.earthGreen)
                }
            }
        }
        .navigationDestination(isPresented: $isBuilding) {
            CustomRouteBuilderView { route in store.save(route) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "map")
                .font(.system(size: 64)).foregroundColor(.earthMuted.opacity(0.4))
            Text("No Saved Routes")
                .font(.headline).foregroundColor(.earthCream)
            Text("Tap + to trace your first custom route")
                .font(.subheadline).foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
            Button { isBuilding = true } label: {
                Label("Create Route", systemImage: "plus")
                    .padding(.horizontal, 24).padding(.vertical, 16)
                    .background(Color.earthOrange).foregroundColor(.white).bold()
                    .cornerRadius(12)
            }
            .padding(.top, 8)
        }
        .padding()
    }

    private var routeList: some View {
        List {
            ForEach(store.routes) { route in
                NavigationLink(destination: CustomRouteDetailView(route: route, historyStore: historyStore)) {
                    CustomRouteRow(route: route)
                }
                .listRowBackground(Color.earthCard)
                .listRowSeparatorTint(Color.earthMuted.opacity(0.2))
            }
            .onDelete { store.delete(at: $0) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Route Row

struct CustomRouteRow: View {
    let route: CustomRoute

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.earthGreen.opacity(0.15))
                    .frame(width: 46, height: 46)
                Image(systemName: route.isLoop ? "arrow.triangle.2.circlepath" : "arrow.right")
                    .foregroundColor(.earthGreen)
                    .font(.system(size: 18, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(route.name).font(.headline).foregroundColor(.earthCream)
                HStack(spacing: 10) {
                    Label(route.distanceText, systemImage: "ruler")
                    Label("~\(route.estimatedSteps.formatted()) steps", systemImage: "figure.walk")
                }
                .font(.footnote).foregroundColor(.earthMuted)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Route Detail

struct CustomRouteDetailView: View {
    let route:  CustomRoute
    @ObservedObject var historyStore: WalkHistoryStore
    @State private var routeLegs:         [MKRoute] = []
    @State private var isLoading          = false
    @State private var routeWeather:      RouteWeather?
    @State private var elevationProfile:  ElevationProfile?
    @State private var isLoadingElevation = false
    @State private var showMapsAlert      = false
    @State private var navigatingRoute:   NavigableRoute?
    @State private var shareState: ShareState = .idle

    private enum ShareState { case idle, sharing, shared, failed }
    private var shareButtonColor: Color {
        switch shareState {
        case .idle:    return Color(red: 0.28, green: 0.49, blue: 0.84)
        case .sharing: return Color(red: 0.28, green: 0.49, blue: 0.84).opacity(0.6)
        case .shared:  return .earthGreen
        case .failed:  return .red.opacity(0.7)
        }
    }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    CustomRouteMapView(
                        waypoints: route.waypoints.map { $0.clCoordinate },
                        routeLegs: routeLegs
                    )
                    if isLoading {
                        ProgressView().tint(.earthGreen)
                            .padding(16)
                            .background(.black.opacity(0.6))
                            .cornerRadius(10)
                    }
                }
                .frame(height: 320)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(route.name)
                                    .font(.title2.bold()).foregroundColor(.earthCream)
                                Label(
                                    route.isLoop ? "Loop route" : "One-way route",
                                    systemImage: route.isLoop ? "arrow.triangle.2.circlepath" : "arrow.right"
                                )
                                .font(.caption).foregroundColor(.earthGreen)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(route.distanceText).font(.title3.bold()).foregroundColor(.earthCream)
                                Text("~\(route.estimatedSteps.formatted()) steps")
                                    .font(.subheadline).foregroundColor(.earthMuted)
                            }
                        }

                        if let weather = routeWeather {
                            WeatherWidget(weather: weather)
                        }

                        if let profile = elevationProfile {
                            ElevationProfileChart(profile: profile)
                        } else if isLoadingElevation {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.earthCard)
                                .frame(height: 80)
                                .overlay {
                                    HStack(spacing: 8) {
                                        ProgressView().tint(.earthGreen)
                                        Text("Calculating elevation...")
                                            .font(.subheadline).foregroundColor(.earthMuted)
                                    }
                                }
                        }

                        HStack(spacing: 12) {
                            infoTile(icon: "mappin.circle",
                                     value: "\(route.waypoints.count)",
                                     label: "waypoints")
                            infoTile(icon: "clock",
                                     value: route.timeText,
                                     label: "est. time")
                        }

                        Button {
                            navigatingRoute = NavigableRoute(
                                name:          route.name,
                                waypoints:     route.waypoints.map { $0.clCoordinate },
                                lapCount:      1,
                                isLoop:        route.isLoop,
                                totalDistance: route.totalDistance
                            )
                        } label: {
                            Label("Start Walk", systemImage: "figure.walk")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18).padding(.horizontal, 20)
                                .background(Color.earthGreen).foregroundColor(.white)
                                .fontWeight(.semibold).cornerRadius(14)
                        }

                        VStack(spacing: 4) {
                            Button {
                                if route.waypoints.count > 2 {
                                    showMapsAlert = true
                                } else {
                                    openInMaps()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "map")
                                    Text("Open in Apple Maps")
                                }
                                .font(.subheadline).foregroundColor(.earthMuted)
                            }
                            Text("Laps and multi-stop routes aren't supported in Apple Maps")
                                .font(.caption)
                                .foregroundColor(.earthMuted.opacity(0.6))
                                .multilineTextAlignment(.center)
                        }
                        .alert("Apple Maps Limitation", isPresented: $showMapsAlert) {
                            Button("Navigate to Start") { openInMapsStartOnly() }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("Apple Maps doesn't support multi-stop walking routes. Wockett will navigate you to the start of your route — follow the in-app map for the full path.")
                        }

                        // Community sharing
                        VStack(spacing: 10) {
                            Divider().background(Color.earthMuted.opacity(0.15))
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Share to Community")
                                        .font(.subheadline.bold()).foregroundColor(.earthCream)
                                    Text("Posting as \(CommunityRouteService.shared.username)")
                                        .font(.caption2).foregroundColor(.earthMuted)
                                }
                                Spacer()
                            }
                            Button {
                                guard shareState == .idle else { return }
                                shareState = .sharing
                                Task {
                                    do {
                                        try await CommunityRouteService.shared.publish(route: route)
                                        shareState = .shared
                                    } catch {
                                        shareState = .failed
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    switch shareState {
                                    case .idle:
                                        Image(systemName: "arrow.up.circle")
                                        Text("Share Route")
                                    case .sharing:
                                        ProgressView().tint(.white).scaleEffect(0.85)
                                        Text("Sharing…")
                                    case .shared:
                                        Image(systemName: "checkmark.circle.fill")
                                        Text("Shared!")
                                    case .failed:
                                        Image(systemName: "exclamationmark.circle")
                                        Text("Couldn't Share")
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(shareButtonColor)
                                .foregroundColor(.white)
                                .fontWeight(.semibold)
                                .cornerRadius(12)
                            }
                            .disabled(shareState != .idle)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)        .navigationDestination(item: $navigatingRoute) { r in
            WalkNavigationView(route: r, historyStore: historyStore)
        }
        .task { await loadLegs() }
    }

    @ViewBuilder
    private func infoTile(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(.earthGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.subheadline.bold()).foregroundColor(.earthCream)
                Text(label).font(.caption).foregroundColor(.earthMuted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.earthCard)
        .cornerRadius(10)
    }

    private func loadLegs() async {
        isLoading = true

        let coords = route.waypoints.map { $0.clCoordinate }
        var legs: [MKRoute] = []

        // Fetch weather in parallel while route legs are loading
        async let weatherFetch = RouteWeatherService.shared.fetchWeather(for: route.centroid)

        for i in 0..<(coords.count - 1) {
            let req           = MKDirections.Request()
            req.source        = MKMapItem(placemark: MKPlacemark(coordinate: coords[i]))
            req.destination   = MKMapItem(placemark: MKPlacemark(coordinate: coords[i + 1]))
            req.transportType = .walking
            if let r = try? await MKDirections(request: req).calculate().routes.first { legs.append(r) }
        }

        if route.isLoop, let first = coords.first, let last = coords.last {
            let req           = MKDirections.Request()
            req.source        = MKMapItem(placemark: MKPlacemark(coordinate: last))
            req.destination   = MKMapItem(placemark: MKPlacemark(coordinate: first))
            req.transportType = .walking
            if let r = try? await MKDirections(request: req).calculate().routes.first { legs.append(r) }
        }

        routeLegs = legs
        isLoading = false

        routeWeather = await weatherFetch

        // Extract all polyline coordinates for elevation — uses route's actual walking path
        let polylineCoords = legs.flatMap { leg -> [CLLocationCoordinate2D] in
            let pts = leg.polyline.points()
            return (0..<leg.polyline.pointCount).map { pts[$0].coordinate }
        }
        if !polylineCoords.isEmpty {
            isLoadingElevation = true
            elevationProfile = try? await ElevationService.shared.fetchProfile(for: polylineCoords)
            isLoadingElevation = false
        }
    }

    // Attempt multi-stop route: current location → each waypoint in order.
    // Apple Maps supports this for driving; walking support varies by iOS version.
    private func openInMaps() {
        let coords = route.waypoints.map { $0.clCoordinate }
        guard !coords.isEmpty else { return }

        var items: [MKMapItem] = [.forCurrentLocation()]
        for (i, coord) in coords.enumerated() {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
            item.name = i == 0 ? "\(route.name) — Start" : "Stop \(i + 1)"
            items.append(item)
        }
        if route.isLoop {
            let ret = MKMapItem(placemark: MKPlacemark(coordinate: coords[0]))
            ret.name = "\(route.name) — Return"
            items.append(ret)
        }
        MKMapItem.openMaps(
            with: items,
            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
        )
    }

    // Fallback for multi-waypoint routes: navigate to start point only
    private func openInMapsStartOnly() {
        guard let first = route.waypoints.first else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: first.clCoordinate))
        item.name = "\(route.name) — Start"
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}
