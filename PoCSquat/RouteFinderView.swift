import SwiftUI
import MapKit
import CloudKit

// MARK: - Route Finder View

struct RouteFinderView: View {
    @ObservedObject var routeManager: RouteManager
    @ObservedObject var historyStore: WalkHistoryStore
    @ObservedObject var routeStore: CustomRouteStore
    @ObservedObject var stepManager: StepManager
    var openWithNearby: Bool = false

    @Environment(\.dismiss) private var dismiss

    // Persisted config
    @State private var selectedRadius: Double
    @State private var walkIntent: WalkIntent
    @State private var activityMode: ActivityMode

    // Route results
    @State private var selectedRoute: SuggestedRoute?
    @State private var routeWeather: RouteWeather?
    @State private var elevationProfile: ElevationProfile?
    @State private var isLoadingElevation = false
    @State private var savedRouteIds: Set<UUID> = []
    @State private var savedCommunityIds: Set<String> = []
    @State private var routeForPosting: SuggestedRoute?

    // Community
    @State private var communityRoutes: [SharedRoute] = []
    @State private var isLoadingCommunity = false
    @State private var showCommunityRoutes = false

    // Navigation & sheets
    @State private var navigatingRoute: NavigableRoute?
    @State private var showNearbySheet = false
    @State private var showDestSearch = false

    private let radiusKey = "wkt_lastRouteRadius_v1"
    private let intentKey = "wkt_lastWalkIntent_v1"

    init(routeManager: RouteManager, historyStore: WalkHistoryStore,
         routeStore: CustomRouteStore, stepManager: StepManager,
         openWithNearby: Bool = false) {
        self.routeManager = routeManager
        self.historyStore = historyStore
        self.routeStore = routeStore
        self.stepManager = stepManager
        self.openWithNearby = openWithNearby

        let r = UserDefaults.standard.double(forKey: "wkt_lastRouteRadius_v1")
        _selectedRadius = State(initialValue: r > 0 ? r : 1000)

        let s = UserDefaults.standard.string(forKey: "wkt_lastWalkIntent_v1") ?? "finishGoal"
        _walkIntent = State(initialValue: WalkIntent(rawStorageString: s))

        let m = UserDefaults.standard.string(forKey: "wkt_lastActivityMode_v1") ?? "walking"
        _activityMode = State(initialValue: ActivityMode(rawValue: m) ?? .walking)
    }

    private var showingConfig: Bool { routeManager.suggestedRoutes.isEmpty }

    var body: some View {
        ZStack(alignment: .bottom) {
            RouteFinderMapView(
                routes: routeManager.suggestedRoutes,
                selectedRoute: $selectedRoute,
                radiusMeters: selectedRadius,
                goalDistanceMeters: Double(stepManager.currentGoal) * 0.762,
                userLocation: routeManager.lastLocation?.coordinate
            )
            .ignoresSafeArea()

            topBar

            if showingConfig {
                configPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                resultsPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: showingConfig)
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            if openWithNearby { showNearbySheet = true }
            if routeManager.lastLocation == nil {
                Task { routeManager.lastLocation = await routeManager.fetchCurrentLocation() }
            }
        }
        .onChange(of: selectedRoute?.id) { _, _ in loadElevation() }
        .onChange(of: selectedRadius) { _, v in
            UserDefaults.standard.set(v, forKey: radiusKey)
        }
        .onChange(of: activityMode) { _, v in
            UserDefaults.standard.set(v.rawValue, forKey: "wkt_lastActivityMode_v1")
            clearRoutes()
        }
        .fullScreenCover(item: $navigatingRoute) { route in
            WalkNavigationView(route: route, historyStore: historyStore)
        }
        .sheet(item: $routeForPosting) { route in
            PostToCommunitySheet(route: route, routeStore: routeStore) {
                savedRouteIds.insert(route.id)
            }
        }
        .sheet(isPresented: $showNearbySheet) {
            NearbyPlacesSheet(fetchLocation: { await routeManager.fetchCurrentLocation() }) { dest, wantsLoop in
                clearRoutes()
                let mode = activityMode
                Task {
                    if wantsLoop {
                        await routeManager.generateLoopDestinationRoute(to: dest, transportType: mode.transportType)
                    } else {
                        await routeManager.generateDestinationRoute(to: dest, transportType: mode.transportType)
                    }
                    await loadWeather()
                }
            }
        }
        .sheet(isPresented: $showDestSearch) {
            DestinationSearchSheet(userLocation: routeManager.lastLocation) { dest in
                clearRoutes()
                let mode = activityMode
                Task {
                    await routeManager.generateDestinationRoute(to: dest, transportType: mode.transportType)
                    await loadWeather()
                }
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                if routeManager.isGenerating {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.8)
                        Text("Finding routes…")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer().frame(width: 44)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Config panel

    private var configPanel: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 20)

            VStack(spacing: 18) {
                HStack(spacing: 8) {
                    activityModeChip(.walking)
                    activityModeChip(.cycling)
                }
                .padding(.horizontal, 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        intentChip(.finishGoal)
                        ForEach(WalkIntent.quickOptions, id: \.self) { mins in
                            intentChip(.quickWalk(minutes: mins))
                        }
                    }
                    .padding(.horizontal, 20)
                }

                VStack(spacing: 8) {
                    HStack {
                        Text("Route reach")
                            .font(.caption.bold())
                            .foregroundColor(.earthMuted)
                        Spacer()
                        Text(formatDistance(selectedRadius))
                            .font(.caption.bold())
                            .foregroundColor(.earthGreen)
                            .monospacedDigit()
                            .animation(.none, value: selectedRadius)
                    }
                    Slider(value: $selectedRadius, in: 200...4_000)
                        .tint(.earthGreen)
                }
                .padding(.horizontal, 20)

                Button(action: triggerRecommend) {
                    Group {
                        if routeManager.isGenerating {
                            HStack(spacing: 10) {
                                ProgressView().tint(.white).scaleEffect(0.9)
                                Text("Finding routes…")
                            }
                        } else {
                            Label("Find Routes", systemImage: "map.fill")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(routeManager.isGenerating ? Color.earthGreen.opacity(0.7) : Color.earthGreen)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .disabled(routeManager.isGenerating)
                .padding(.horizontal, 20)

                if let err = routeManager.locationError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                        Text(err)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 20)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HStack(spacing: 20) {
                    Button { showDestSearch = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                            Text("Search a place")
                        }
                        .font(.caption)
                        .foregroundColor(.earthMuted)
                    }
                    Rectangle()
                        .fill(Color.earthMuted.opacity(0.3))
                        .frame(width: 1, height: 14)
                    Button { showNearbySheet = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill")
                            Text("Nearby places")
                        }
                        .font(.caption)
                        .foregroundColor(.earthMuted)
                    }
                }
                .padding(.bottom, 4)
            }
            .padding(.bottom, 36)
            .animation(.spring(response: 0.35), value: routeManager.locationError != nil)
        }
        .background(.ultraThinMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
    }

    // MARK: - Results panel

    private var resultsPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { clearRoutes() } label: {
                    Label("New Search", systemImage: "arrow.clockwise")
                        .font(.caption.bold())
                        .foregroundColor(.earthGreen)
                }
                .frame(width: 110, alignment: .leading)

                Capsule()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 36, height: 4)
                    .frame(maxWidth: .infinity)

                Color.clear.frame(width: 110, height: 1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 14)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    if let weather = routeWeather {
                        WeatherWidget(weather: weather)
                            .padding(.horizontal, 20)
                    }

                    if let err = routeManager.locationError {
                        Text(err)
                            .font(.caption).foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }

                    let total = routeManager.suggestedRoutes.count
                    ForEach(routeManager.suggestedRoutes) { route in
                        RouteCard(
                            route: route,
                            isSelected: selectedRoute?.id == route.id,
                            totalRoutes: total,
                            isSaved: savedRouteIds.contains(route.id),
                            onSelect: {
                                withAnimation(.spring(response: 0.3)) {
                                    selectedRoute = (selectedRoute?.id == route.id) ? nil : route
                                }
                            },
                            onSave: {
                                routeStore.save(route.toCustomRoute())
                                savedRouteIds.insert(route.id)
                            },
                            onPost: { routeForPosting = route }
                        )
                        .padding(.horizontal, 20)
                    }

                    if let selected = selectedRoute {
                        elevationSection
                        startWalkButton(for: selected)
                        appleMapsButton(for: selected)
                    }

                    communitySection
                }
                .padding(.bottom, 40)
                .animation(.easeInOut(duration: 0.2), value: selectedRoute?.id)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: elevationProfile == nil)
            }
            .frame(maxHeight: UIScreen.main.bounds.height * 0.35)
        }
        .background(.ultraThinMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
    }

    @ViewBuilder
    private var elevationSection: some View {
        if let profile = elevationProfile {
            ElevationProfileChart(profile: profile)
                .padding(.horizontal, 20)
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else if isLoadingElevation {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.earthCard)
                .frame(height: 80)
                .overlay(ProgressView().tint(.earthGreen))
                .padding(.horizontal, 20)
        }
    }

    private func startWalkButton(for route: SuggestedRoute) -> some View {
        Button { navigatingRoute = route.toNavigableRoute(activityMode: activityMode) } label: {
            Label("Start \(activityMode.sessionLabel)", systemImage: activityMode.icon)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color.earthGreen)
                .foregroundColor(.white)
                .cornerRadius(14)
        }
        .padding(.horizontal, 20)
    }

    private func appleMapsButton(for route: SuggestedRoute) -> some View {
        VStack(spacing: 4) {
            Button { route.openInAppleMaps(activityMode: activityMode) } label: {
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
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Community section

    @ViewBuilder
    private var communitySection: some View {
        VStack(spacing: 10) {
            Button {
                showCommunityRoutes.toggle()
                if showCommunityRoutes && communityRoutes.isEmpty {
                    Task { await loadCommunityRoutes() }
                }
            } label: {
                HStack {
                    Label("Community Routes", systemImage: "person.2.fill")
                        .font(.subheadline.bold())
                        .foregroundColor(.earthCream)
                    Spacer()
                    if isLoadingCommunity {
                        ProgressView().tint(.earthGreen).scaleEffect(0.8)
                    } else {
                        Image(systemName: showCommunityRoutes ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundColor(.earthMuted)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Color.earthCard)
                .cornerRadius(12)
                .padding(.horizontal, 20)
            }

            if showCommunityRoutes {
                if communityRoutes.isEmpty && !isLoadingCommunity {
                    Text("No routes shared yet — be the first!")
                        .font(.caption).foregroundColor(.earthMuted)
                        .padding(.vertical, 8)
                } else {
                    ForEach($communityRoutes) { $route in
                        CommunityRouteCard(
                            route: $route,
                            hasVoted: CommunityRouteService.shared.hasVoted(for: route.id),
                            isSaved: savedCommunityIds.contains(route.id.recordName),
                            onUpvote: {
                                guard !CommunityRouteService.shared.hasVoted(for: route.id) else { return }
                                route.upvotes += 1
                                CommunityRouteService.shared.markVoted(for: route.id)
                                Task { try? await CommunityRouteService.shared.upvote(id: route.id) }
                            },
                            onSave: {
                                routeStore.save(CustomRoute(
                                    id: UUID(),
                                    name: route.name,
                                    waypoints: route.waypoints,
                                    totalDistance: route.distanceMeters,
                                    isLoop: route.isLoop,
                                    createdAt: Date()
                                ))
                                savedCommunityIds.insert(route.id.recordName)
                            },
                            onStart: { navigatingRoute = route.toNavigableRoute() }
                        )
                        .padding(.horizontal, 20)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCommunityRoutes)
    }

    // MARK: - Helpers

    private func activityModeChip(_ mode: ActivityMode) -> some View {
        let isSelected = activityMode == mode
        return Button {
            activityMode = mode
        } label: {
            Label(mode.sessionLabel, systemImage: mode.icon)
                .font(.caption.bold())
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(isSelected ? Color.earthGreen : Color.earthCard)
                .foregroundColor(isSelected ? .white : .earthCream)
                .cornerRadius(20)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.94))
        .animation(.spring(response: 0.2), value: isSelected)
        .frame(maxWidth: .infinity)
    }

    private func intentChip(_ intent: WalkIntent) -> some View {
        let isSelected = walkIntent == intent
        return Button {
            walkIntent = intent
            saveIntent()
        } label: {
            Text(intent.label)
                .font(.caption.bold())
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(isSelected ? Color.earthGreen : Color.earthCard)
                .foregroundColor(isSelected ? .white : .earthCream)
                .cornerRadius(20)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.94))
        .animation(.spring(response: 0.2), value: isSelected)
    }

    private func triggerRecommend() {
        clearRoutes()
        Task {
            let target: Double = {
                switch walkIntent {
                case .finishGoal:
                    let r = stepManager.remainingMeters
                    return r > 100 ? r : 5000
                case .quickWalk(let mins):
                    return Double(mins) * 80
                }
            }()
            await routeManager.generateRoutes(remainingMeters: target, radius: selectedRadius, transportType: activityMode.transportType)
            await loadWeather()
        }
    }

    private func clearRoutes() {
        routeManager.suggestedRoutes = []
        routeManager.locationError = nil
        selectedRoute = nil
        routeWeather = nil
        elevationProfile = nil
    }

    private func loadElevation() {
        guard let coords = selectedRoute?.legWaypoints, coords.count >= 2 else {
            elevationProfile = nil
            isLoadingElevation = false
            return
        }
        isLoadingElevation = true
        elevationProfile = nil
        Task {
            elevationProfile = try? await ElevationService.shared.fetchProfile(for: coords)
            isLoadingElevation = false
        }
    }

    private func loadWeather() async {
        guard let loc = routeManager.lastLocation, !routeManager.suggestedRoutes.isEmpty else { return }
        routeWeather = await RouteWeatherService.shared.fetchWeather(for: loc.coordinate)
    }

    private func saveIntent() {
        switch walkIntent {
        case .finishGoal:
            UserDefaults.standard.set("finishGoal", forKey: intentKey)
        case .quickWalk(let mins):
            UserDefaults.standard.set("quickWalk:\(mins)", forKey: intentKey)
        }
    }

    private func loadCommunityRoutes() async {
        isLoadingCommunity = true
        communityRoutes = (try? await CommunityRouteService.shared.fetchRoutes()) ?? []
        isLoadingCommunity = false
    }

    private func formatDistance(_ meters: Double) -> String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: meters)
    }
}

// MARK: - WalkIntent persistence helpers

// MARK: - Marker overlay for checkpoint / finish

final class MarkerCircle: MKCircle {
    var isFinish = false
}

// MARK: - WalkIntent persistence helpers

extension WalkIntent {
    init(rawStorageString: String) {
        if rawStorageString.hasPrefix("quickWalk:"),
           let mins = Int(rawStorageString.dropFirst("quickWalk:".count)) {
            self = .quickWalk(minutes: mins)
        } else {
            self = .finishGoal
        }
    }
}

// MARK: - Route Finder Map View

struct RouteFinderMapView: UIViewRepresentable {
    let routes: [SuggestedRoute]
    @Binding var selectedRoute: SuggestedRoute?
    let radiusMeters: Double
    let goalDistanceMeters: Double
    let userLocation: CLLocationCoordinate2D?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.overrideUserInterfaceStyle = .unspecified
        if let loc = userLocation {
            context.coordinator.hasSetInitialRegion = true
            let span = max(goalDistanceMeters * 2.5, 1500)
            map.setRegion(MKCoordinateRegion(center: loc, latitudinalMeters: span, longitudinalMeters: span), animated: false)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        if let loc = userLocation, !context.coordinator.hasSetInitialRegion {
            context.coordinator.hasSetInitialRegion = true
            let span = max(goalDistanceMeters * 2.5, 1500)
            map.setRegion(MKCoordinateRegion(center: loc, latitudinalMeters: span, longitudinalMeters: span), animated: false)
        }

        let currentIds = routes.map { $0.id }

        if context.coordinator.lastRouteIds != currentIds {
            context.coordinator.lastRouteIds = currentIds
            context.coordinator.lastSelectedId = UUID()  // reset sentinel

            map.removeOverlays(map.overlays.filter { !($0 is MKCircle) })

            if routes.isEmpty {
                updateRadiusCircle(on: map, context: context)
                if let loc = userLocation {
                    let region = MKCoordinateRegion(
                        center: loc,
                        latitudinalMeters: radiusMeters * 3.5,
                        longitudinalMeters: radiusMeters * 3.5
                    )
                    map.setRegion(region, animated: true)
                }
            } else {
                map.removeOverlays(map.overlays.filter { $0 is MKCircle })
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
                    // Extra bottom padding so routes show above the results panel
                    map.setVisibleMapRect(
                        rect,
                        edgePadding: UIEdgeInsets(top: 80, left: 40, bottom: 420, right: 40),
                        animated: true
                    )
                }
            }
        }

        if routes.isEmpty {
            updateRadiusCircle(on: map, context: context)
        }

        // Selection rendering
        let newSelectedId = selectedRoute?.id
        if context.coordinator.lastSelectedId != newSelectedId {
            context.coordinator.lastSelectedId = newSelectedId

            // Checkpoint + finish overlays for the selected route
            map.removeOverlays(map.overlays.filter { $0 is MarkerCircle })
            if let sel = selectedRoute {
                for fraction in [0.25, 0.5, 0.75] {
                    if let c = Self.coordAlong(sel.polyline, fraction: fraction) {
                        let circle = MarkerCircle(center: c, radius: 22)
                        map.addOverlay(circle, level: .aboveRoads)
                    }
                }
                if let last = sel.legWaypoints.last {
                    let finish = MarkerCircle(center: last, radius: 28)
                    finish.isFinish = true
                    map.addOverlay(finish, level: .aboveRoads)
                }
            }

            let total = routes.count
            let hasSelection = selectedRoute != nil
            for overlay in map.overlays {
                guard let pl = overlay as? MKPolyline,
                      let renderer = map.renderer(for: overlay) as? MKPolylineRenderer,
                      let route = routes.first(where: { $0.id.uuidString == pl.title }) else { continue }
                let isSelected = route.id == newSelectedId
                renderer.strokeColor = SuggestedRoute.paletteUIColor(index: route.colorIndex, total: total)
                renderer.lineWidth = isSelected ? 6 : 3
                renderer.alpha = isSelected ? 1.0 : (hasSelection ? 0.2 : 0.6)
                renderer.setNeedsDisplay()
            }
            if let sel = selectedRoute {
                var rect = MKMapRect.null
                let pts = sel.polyline.points()
                for i in 0..<sel.polyline.pointCount {
                    let p = MKMapPoint(pts[i].coordinate)
                    rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
                if !rect.isNull {
                    map.setVisibleMapRect(
                        rect,
                        edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 440, right: 40),
                        animated: true
                    )
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
                    map.setVisibleMapRect(
                        rect,
                        edgePadding: UIEdgeInsets(top: 80, left: 40, bottom: 420, right: 40),
                        animated: true
                    )
                }
            }
        }
    }

    private func updateRadiusCircle(on map: MKMapView, context: Context) {
        guard let center = userLocation else { return }
        if abs(context.coordinator.lastRadius - radiusMeters) > 10
            || map.overlays.filter({ $0 is MKCircle }).isEmpty {
            map.removeOverlays(map.overlays.filter { $0 is MKCircle })
            map.addOverlay(MKCircle(center: center, radius: radiusMeters), level: .aboveRoads)
            context.coordinator.lastRadius = radiusMeters
        }
    }

    static func coordAlong(_ polyline: MKPolyline, fraction: Double) -> CLLocationCoordinate2D? {
        let n = polyline.pointCount
        guard n > 1, fraction > 0 else { return polyline.points()[0].coordinate }
        if fraction >= 1 { return polyline.points()[n - 1].coordinate }
        let pts = polyline.points()
        var total = 0.0
        var lens = [Double]()
        for i in 0..<n - 1 {
            let a = CLLocation(latitude: pts[i].coordinate.latitude, longitude: pts[i].coordinate.longitude)
            let b = CLLocation(latitude: pts[i + 1].coordinate.latitude, longitude: pts[i + 1].coordinate.longitude)
            let d = a.distance(from: b)
            lens.append(d); total += d
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RouteFinderMapView
        var lastRouteIds: [UUID] = []
        var lastSelectedId: UUID? = UUID()
        var lastRadius: Double = -1
        var hasSetInitialRegion = false
        init(_ p: RouteFinderMapView) { parent = p }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let marker = overlay as? MarkerCircle {
                let r = MKCircleRenderer(circle: marker)
                if marker.isFinish {
                    r.fillColor = UIColor.systemOrange.withAlphaComponent(0.35)
                    r.strokeColor = UIColor.systemOrange
                    r.lineWidth = 2
                } else {
                    r.fillColor = UIColor.white.withAlphaComponent(0.45)
                    r.strokeColor = UIColor.systemGray2
                    r.lineWidth = 1.5
                }
                return r
            }
            if let circle = overlay as? MKCircle {
                let r = MKCircleRenderer(circle: circle)
                r.strokeColor = UIColor.systemGreen.withAlphaComponent(0.45)
                r.fillColor = UIColor.systemGreen.withAlphaComponent(0.07)
                r.lineWidth = 1.5
                return r
            }
            guard let pl = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: pl)
            let total = parent.routes.count
            let hasSelection = parent.selectedRoute != nil
            if let route = parent.routes.first(where: { $0.id.uuidString == pl.title }) {
                let isSelected = route.id == parent.selectedRoute?.id
                r.strokeColor = SuggestedRoute.paletteUIColor(index: route.colorIndex, total: total)
                r.lineWidth = isSelected ? 6 : 3
                r.alpha = isSelected ? 1.0 : (hasSelection ? 0.2 : 0.6)
            }
            return r
        }
    }
}
