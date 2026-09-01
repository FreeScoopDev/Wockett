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
    @State private var showCommunityRoutes = true
    @State private var communityLoadError: String? = nil

    // Navigation & sheets
    @State private var showNearbySheet = false
    @State private var showDestSearch = false
    @State private var showActiveSessionAlert = false

    // Active search task — stored so it can be cancelled on retry or dismissal
    @State private var activeTask: Task<Void, Never>?

    // Elevation fetch — per-route cache prevents re-fetching on re-selection
    @State private var elevationTask:  Task<Void, Never>? = nil
    @State private var elevationCache: [UUID: ElevationProfile] = [:]
    @State private var elevationError: String? = nil

    @State private var wocketError: String? = nil

    private let intentKey = "wkt_lastWalkIntent_v1"

    init(routeManager: RouteManager, historyStore: WalkHistoryStore,
         routeStore: CustomRouteStore, stepManager: StepManager,
         openWithNearby: Bool = false) {
        self.routeManager = routeManager
        self.historyStore = historyStore
        self.routeStore = routeStore
        self.stepManager = stepManager
        self.openWithNearby = openWithNearby

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
            Task { await loadCommunityRoutes() }
        }
        .onDisappear {
            clearRoutes()
        }
        .onChange(of: selectedRoute?.id) { _, _ in loadElevation() }
        .onChange(of: activityMode) { _, v in
            UserDefaults.standard.set(v.rawValue, forKey: "wkt_lastActivityMode_v1")
            clearRoutes()
        }
        .alert("Session Already Active", isPresented: $showActiveSessionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You have a session in progress. Return to the home screen to resume or end it first.")
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
                    activityModeChip(.running)
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

                    Button(action: triggerNearbyLoops) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Try nearby loops instead")
                        }
                        .font(.subheadline.bold())
                        .foregroundColor(.earthGreen)
                    }
                    .padding(.horizontal, 20)
                    .transition(.opacity)
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
                                let count = UserDefaults.standard.integer(forKey: "wkt_routesBookmarked_count")
                                UserDefaults.standard.set(count + 1, forKey: "wkt_routesBookmarked_count")
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
        } else if let err = elevationError {
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.caption)
                Text(err)
                    .font(.caption)
            }
            .foregroundColor(.earthMuted)
            .padding(.horizontal, 20)
        }
    }

    private func startWalkButton(for route: SuggestedRoute) -> some View {
        Button {
            let nav = route.toNavigableRoute(activityMode: activityMode)
            guard ActiveWalkStore.shared.beginSession(route: nav) != nil else {
                showActiveSessionAlert = true
                return
            }
            // Dismiss RouteFinderView — StepCounterView will auto-present WalkNavigationView.
            // Using dismiss() here avoids a nested fullScreenCover that can silently fail.
            dismiss()
        } label: {
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
            if let err = wocketError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                    Text(err)
                        .font(.caption)
                }
                .foregroundColor(.orange)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .transition(.opacity)
            }

            Button {
                showCommunityRoutes.toggle()
                if showCommunityRoutes && communityRoutes.isEmpty && communityLoadError == nil {
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
                if isLoadingCommunity {
                    ProgressView("Loading routes…")
                        .font(.caption).foregroundColor(.earthMuted)
                        .padding(.vertical, 12)
                } else if let error = communityLoadError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.icloud")
                            .font(.system(size: 28))
                            .foregroundColor(.earthMuted)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.earthMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button {
                            communityLoadError = nil
                            Task { await loadCommunityRoutes() }
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.caption.bold())
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(Color.earthCard)
                                .foregroundColor(.earthGreen)
                                .cornerRadius(8)
                        }
                    }
                    .padding(.vertical, 12)
                } else if communityRoutes.isEmpty {
                    Text("No routes shared yet — be the first!")
                        .font(.caption).foregroundColor(.earthMuted)
                        .padding(.vertical, 8)
                } else {
                    ForEach($communityRoutes) { $route in
                        CommunityRouteCard(
                            route: $route,
                            hasVoted: CommunityRouteService.shared.hasVoted(for: route.id),
                            isSaved: savedCommunityIds.contains(route.id.recordName),
                            onWockett: {
                                guard !CommunityRouteService.shared.hasVoted(for: route.id) else { return }
                                route.wocketts += 1
                                CommunityRouteService.shared.markVoted(for: route.id)
                                Task {
                                    do {
                                        try await CommunityRouteService.shared.wockett(id: route.id)
                                    } catch {
                                        wocketError = "Couldn't save your Wockett — check your connection and try again."
                                    }
                                }
                            },
                            onSave: {
                                routeStore.save(CustomRoute(
                                    id: UUID(),
                                    name: route.name,
                                    waypoints: route.waypoints,
                                    totalDistance: route.distanceMeters,
                                    isLoop: route.isLoop,
                                    createdAt: Date(),
                                    activityMode: activityMode
                                ))
                                savedCommunityIds.insert(route.id.recordName)
                                let count = UserDefaults.standard.integer(forKey: "wkt_routesBookmarked_count")
                                UserDefaults.standard.set(count + 1, forKey: "wkt_routesBookmarked_count")
                            },
                            onStart: {
                                var nav = route.toNavigableRoute()
                                nav.isCommunityRoute = true
                                guard ActiveWalkStore.shared.beginSession(route: nav) != nil else {
                                    showActiveSessionAlert = true
                                    return
                                }
                                dismiss()
                            },
                            onHide: { communityRoutes.removeAll { $0.id == route.id } }
                        )
                        .padding(.horizontal, 20)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCommunityRoutes)
        .animation(.easeInOut(duration: 0.2), value: communityLoadError)
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
        activeTask = Task {
            let target: Double = {
                switch walkIntent {
                case .finishGoal:
                    let r = stepManager.remainingMeters
                    // Below ~650 steps remaining (500m), suggest a short finishing walk
                    // rather than jumping to a full 5km fallback.
                    return r > 500 ? r : 1500
                case .quickWalk(let mins):
                    return Double(mins) * 80
                }
            }()
            await routeManager.generateRoutes(remainingMeters: target, transportType: activityMode.transportType)
            guard !Task.isCancelled else { return }
            await loadWeather()
        }
    }

    private func triggerNearbyLoops() {
        clearRoutes()
        activeTask = Task {
            let target: Double = {
                switch walkIntent {
                case .finishGoal:
                    let r = stepManager.remainingMeters
                    // Below ~650 steps remaining (500m), suggest a short finishing walk
                    // rather than jumping to a full 5km fallback.
                    return r > 500 ? r : 1500
                case .quickWalk(let mins):
                    return Double(mins) * 80
                }
            }()
            await routeManager.generateNearbyLoops(remainingMeters: target, transportType: activityMode.transportType)
            guard !Task.isCancelled else { return }
            await loadWeather()
        }
    }

    private func clearRoutes() {
        activeTask?.cancel()
        activeTask = nil
        elevationTask?.cancel()
        elevationTask = nil
        routeManager.isGenerating = false
        routeManager.suggestedRoutes = []
        routeManager.locationError = nil
        selectedRoute = nil
        routeWeather = nil
        elevationProfile = nil
        elevationError = nil
        wocketError = nil
    }

    private func loadElevation() {
        guard let route = selectedRoute, route.legWaypoints.count >= 2 else {
            elevationProfile = nil
            elevationError = nil
            isLoadingElevation = false
            return
        }
        // Serve from cache — avoid re-fetching when the user re-selects the same route.
        if let cached = elevationCache[route.id] {
            elevationProfile = cached
            elevationError = nil
            isLoadingElevation = false
            return
        }
        elevationTask?.cancel()
        isLoadingElevation = true
        elevationProfile = nil
        elevationError = nil
        elevationTask = Task {
            do {
                let profile = try await ElevationService.shared.fetchProfile(for: route.legWaypoints)
                guard !Task.isCancelled else { return }
                elevationProfile = profile
                elevationCache[route.id] = profile
            } catch {
                guard !Task.isCancelled else { return }
                elevationError = "Elevation data unavailable"
            }
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
        communityLoadError = nil
        do {
            communityRoutes = try await CommunityRouteService.shared.fetchRoutes()
        } catch let ckError as CKError {
            switch ckError.code {
            case .notAuthenticated:
                communityLoadError = "Sign into iCloud (Settings → [Your Name]) to view community routes."
            case .networkUnavailable, .networkFailure:
                communityLoadError = "No internet connection. Check your connection and retry."
            case .unknownItem, .invalidArguments, .internalError:
                communityLoadError = "Community routes aren't set up yet — open CloudKit Console and deploy SharedRoute to Production."
            case .serviceUnavailable:
                communityLoadError = "iCloud is temporarily unavailable. Try again in a moment."
            default:
                communityLoadError = "Couldn't load routes (error \(ckError.code.rawValue)). Tap to retry."
            }
        } catch {
            communityLoadError = "Couldn't load routes: \(error.localizedDescription)"
        }
        isLoadingCommunity = false
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

            map.removeOverlays(map.overlays.filter { $0 is MKPolyline || $0 is MarkerCircle })

            if routes.isEmpty {
                // No routes — map stays at its current zoom.
            } else {
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
