import SwiftUI
import MapKit
import CloudKit

// MARK: - Route Finder Content View (push-safe, no dismiss chrome)
//
// Use this directly as the Routes tab root. Pass onNavigateAway to handle
// post-startWalk navigation (tab switch or sheet dismiss).

struct RouteFinderContentView: View {
    @ObservedObject var routeManager: RouteManager
    @ObservedObject var historyStore: WalkHistoryStore
    @ObservedObject var routeStore: CustomRouteStore
    @ObservedObject var stepManager: StepManager
    var onNavigateAway: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    @EnvironmentObject private var tabRouter: TabRouter

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
    @Environment(CommunityRoutesModel.self) private var communityModel
    @State private var showCommunityRoutes = true

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

    // Trails — the Routes | Trails switch (design agreed 2026-09-23).
    private enum Mode: Hashable { case routes, trails }
    @State private var mode: Mode = .routes
    @State private var trailFinder = TrailFinder()
    @State private var selectedTrail: TrailListItem?
    /// A trail another tab asked to open, kept until the list holds it:
    /// switching to Trails clears the selection, and the list can arrive
    /// only once a location does.
    @State private var pendingOpenTrailID: String?
    @AppStorage("wkt_trails_groupSections_v1") private var groupTrailSections = true
    @AppStorage("wkt_trails_showShortPaths_v1") private var showShortTrailPaths = false
    /// Measured, so the map frames a trail in the part the panel leaves visible.
    @State private var trailPanelHeight: CGFloat = 0

    private let intentKey = "wkt_lastWalkIntent_v1"

    init(routeManager: RouteManager, historyStore: WalkHistoryStore,
         routeStore: CustomRouteStore, stepManager: StepManager,
         onNavigateAway: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        self.routeManager = routeManager
        self.historyStore = historyStore
        self.routeStore = routeStore
        self.stepManager = stepManager
        self.onNavigateAway = onNavigateAway
        self.onDismiss = onDismiss

        let s = UserDefaults.standard.string(forKey: "wkt_lastWalkIntent_v1") ?? "finishGoal"
        _walkIntent = State(initialValue: WalkIntent(rawStorageString: s))

        let m = UserDefaults.standard.string(forKey: "wkt_lastActivityMode_v1") ?? "walking"
        _activityMode = State(initialValue: ActivityMode(rawValue: m) ?? .walking)
    }

    private var showingConfig: Bool { routeManager.suggestedRoutes.isEmpty }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RouteFinderMapView(
                    routes: mode == .routes ? routeManager.suggestedRoutes : [],
                    selectedRoute: mode == .routes ? $selectedRoute : .constant(nil),
                    goalDistanceMeters: Double(stepManager.currentGoal) * 0.762,
                    userLocation: mode == .trails ? trailCenter : routeManager.lastLocation?.coordinate,
                    trails: mode == .trails ? trailFinder.items : [],
                    selectedTrailID: mode == .trails ? selectedTrail?.id : nil,
                    mutedBase: mode == .trails,
                    bottomInset: trailPanelHeight + geo.safeAreaInsets.bottom,
                    onTrailTap: mode == .trails ? { id in
                        guard let item = trailFinder.items.first(where: { $0.id == id }) else { return }
                        withAnimation(.spring(response: 0.3)) { selectedTrail = item }
                    } : nil
                )
                .ignoresSafeArea()
                .safeAreaInset(edge: .bottom) {
                    if mode == .trails {
                        TrailsPanel(
                            finder: trailFinder,
                            selected: $selectedTrail,
                            groupSections: $groupTrailSections,
                            includeShortPaths: $showShortTrailPaths,
                            userLocation: trailCenter,
                            activityMode: activityMode,
                            containerHeight: geo.size.height,
                            modePicker: AnyView(modePicker),
                            onStart: { plan in
                                let nav = plan.navigableRoute(activityMode: activityMode)
                                guard ActiveWalkStore.shared.beginSession(route: nav) != nil else {
                                    showActiveSessionAlert = true
                                    return
                                }
                                onNavigateAway?()
                            }
                        )
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { trailPanelHeight = $0 }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if showingConfig {
                        configPanel()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        resultsPanel(containerHeight: geo.size.height)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                topBar
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: showingConfig)
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: mode)
        .onChange(of: mode) { _, newMode in
            selectedTrail = nil
            if newMode == .trails { refreshTrails() }
        }
        .onChange(of: trailFinder.filters) { _, _ in refreshTrails() }
        .onChange(of: groupTrailSections) { _, _ in
            selectedTrail = nil
            refreshTrails()
        }
        .onChange(of: showShortTrailPaths) { _, _ in refreshTrails() }
        .onChange(of: routeManager.lastLocation) { _, _ in
            if mode == .trails { refreshTrails() }
        }
        .onAppear {
            if let dest = tabRouter.pendingRoutesDestination { open(dest) }
            if routeManager.lastLocation == nil {
                Task { routeManager.lastLocation = await routeManager.fetchCurrentLocation() }
            }
            if !isWKTUITestMode { Task { await communityModel.load() } }
        }
        .onDisappear {
            clearRoutes()
        }
        .onChange(of: tabRouter.pendingRoutesDestination) { _, dest in
            if let dest { open(dest) }
        }
        .onChange(of: selectedRoute?.id) { _, _ in loadElevation() }
        .onChange(of: activityMode) { _, v in
            UserDefaults.standard.set(v.rawValue, forKey: "wkt_lastActivityMode_v1")
            clearRoutes()
            if mode == .trails { refreshTrails() }
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
                if let dismiss = onDismiss {
                    Button { dismiss() } label: {
                        Image(wkt: .chevronLeft)
                            .wktIcon(.row, tint: .primary)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Back")
                } else {
                    Spacer().frame(width: 44)
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

    // MARK: - Routes | Trails

    private var modePicker: some View {
        Picker("Show", selection: $mode) {
            Text("Routes").tag(Mode.routes)
            Text("Trails").tag(Mode.trails)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("routes.modePicker")
    }

    /// Under -WKTUITest RouteManager reports Times Square, where there is no
    /// trail pack, so the Trails list searches from downtown Raleigh instead
    /// and the smoke test has real data. Compiled out of release builds.
    private var trailCenter: CLLocationCoordinate2D? {
        isWKTUITestMode
            ? CLLocationCoordinate2D(latitude: 35.7796, longitude: -78.6382)
            : routeManager.lastLocation?.coordinate
    }

    /// A destination another tab asked for.
    private func open(_ destination: RoutesDestination) {
        tabRouter.pendingRoutesDestination = nil
        switch destination {
        case .nearby:
            showNearbySheet = true
        case .trails(let openTrailID):
            pendingOpenTrailID = openTrailID
            if mode != .trails {
                mode = .trails   // onChange(of: mode) refreshes and opens it
            } else {
                refreshTrails()
            }
        }
    }

    private func openPendingTrail() {
        guard let id = pendingOpenTrailID, !trailFinder.items.isEmpty else { return }
        pendingOpenTrailID = nil
        if let item = trailFinder.items.first(where: { $0.id == id }) {
            withAnimation(.spring(response: 0.3)) { selectedTrail = item }
        }
    }

    private func refreshTrails() {
        trailFinder.refresh(near: trailCenter,
                            grouped: groupTrailSections,
                            cycling: activityMode == .cycling,
                            usesMiles: Locale.current.measurementSystem == .us,
                            includeShortPaths: showShortTrailPaths)
        if let current = selectedTrail, !trailFinder.items.contains(where: { $0.id == current.id }) {
            selectedTrail = nil
        }
        openPendingTrail()
    }

    // MARK: - Config panel

    private func configPanel() -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 20)

            VStack(spacing: 18) {
                modePicker
                    .padding(.horizontal, 20)

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
                            Label {
                                Text("Find Routes")
                            } icon: {
                                Image(wkt: .mapFill).wktIcon(.row, tint: .white, onFill: true)
                            }
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(routeManager.isGenerating ? Color.earthGreenFill.opacity(0.7) : Color.earthGreenFill)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .disabled(routeManager.isGenerating)
                .accessibilityIdentifier("routes.findRoutes")
                .padding(.horizontal, 20)

                if let err = routeManager.locationError {
                    HStack(spacing: 6) {
                        Image(wkt: .warning).wktIcon(.inline, tint: .orange, filled: true)
                        Text(err)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 20)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                    Button(action: triggerNearbyLoops) {
                        HStack(spacing: 6) {
                            Image(wkt: .loop).wktIcon(.inline, tint: .earthGreen)
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
                            Image(wkt: .find).wktIcon(.inline, tint: .earthMuted)
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
                            Image(wkt: .locationOn).wktIcon(.inline, tint: .earthMuted)
                            Text("Nearby places")
                        }
                        .font(.caption)
                        .foregroundColor(.earthMuted)
                    }
                }
                .padding(.bottom, 4)
            }
            // 14, not 14 + safeAreaInsets.bottom. Measured on an iPhone 17
            // (2026-09-05): this panel's content already ends exactly at the top of
            // the tab bar (y=791) on its own, because .safeAreaInset places its
            // content inside the container's safe area even though the map beneath
            // it calls .ignoresSafeArea(). Adding the inset a second time pushed the
            // bottom row to 101pt above the bar instead of 18pt — an empty band, not
            // a fix for anything. The panel was never clipped.
            .padding(.bottom, 14)
            .animation(.spring(response: 0.35), value: routeManager.locationError != nil)
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
        .background(.ultraThinMaterial, ignoresSafeAreaEdges: .bottom)
    }

    // MARK: - Results panel

    private func resultsPanel(containerHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { clearRoutes() } label: {
                    Label {
                        Text("New Search")
                    } icon: {
                        Image(wkt: .refresh).wktIcon(.inline, tint: .earthGreen)
                    }
                    .font(.caption.bold())
                    .foregroundColor(.earthGreen)
                }
                .accessibilityIdentifier("routes.newSearch")
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

            modePicker
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    if let weather = routeWeather {
                        WeatherWidget(weather: weather, initiallyExpanded: false)
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
                        // Selecting a card is what reveals the Start Walk button, so
                        // the smoke test needs a way to address one.
                        .accessibilityIdentifier("routes.routeCard")
                        .padding(.horizontal, 20)
                    }

                    if let selected = selectedRoute {
                        elevationSection
                        startWalkButton(for: selected)
                        appleMapsButton(for: selected)
                    }

                    communitySection
                }
                // 14, not 14 + safeAreaInsets.bottom — same reason as configPanel.
                // Here the extra inset had no measurable effect whatsoever: this
                // padding sits below the content inside a ScrollView, so it can only
                // add trailing scroll space, never move anything above it. What
                // actually fixed the "cards cut off" report was the 0.45 height cap
                // below and the compact weather tile, both in the same commit.
                .padding(.bottom, 14)
                .animation(.easeInOut(duration: 0.2), value: selectedRoute?.id)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: elevationProfile == nil)
            }
            // 0.35 left the route list and Start Walk below the fold on a fresh
            // search; 0.45 puts at least two cards in the first screenful.
            .frame(maxHeight: containerHeight * 0.45)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routes.resultsPanel")
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
        .background(.ultraThinMaterial, ignoresSafeAreaEdges: .bottom)
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
                Image(wkt: .elevation).wktIcon(.inline, tint: .earthMuted)
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
            onNavigateAway?()
        } label: {
            Label("Start \(activityMode.sessionLabel)", systemImage: activityMode.icon)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color.earthGreenFill)
                .foregroundColor(.white)
                .cornerRadius(14)
        }
        .accessibilityIdentifier("routes.startWalk")
        .padding(.horizontal, 20)
    }

    private func appleMapsButton(for route: SuggestedRoute) -> some View {
        VStack(spacing: 4) {
            Button { route.openInAppleMaps(activityMode: activityMode) } label: {
                HStack(spacing: 4) {
                    Image(wkt: .openInMaps).wktIcon(.inline, tint: .earthMuted)
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
                    Image(wkt: .errorCircle).wktIcon(.inline, tint: .orange, filled: true)
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
                if showCommunityRoutes && communityModel.routes.isEmpty && communityModel.loadError == nil && !communityModel.didLoad {
                    Task { await communityModel.load() }
                }
            } label: {
                HStack {
                    Label {
                        Text("Community Routes")
                    } icon: {
                        Image(wkt: .communityFill).wktIcon(.inline, tint: .earthCream, filled: true)
                    }
                    .font(.subheadline.bold())
                    .foregroundColor(.earthCream)
                    Spacer()
                    if communityModel.isLoading {
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
                if communityModel.isLoading && communityModel.routes.isEmpty {
                    ProgressView("Loading routes…")
                        .font(.caption).foregroundColor(.earthMuted)
                        .padding(.vertical, 12)
                } else if let error = communityModel.loadError, communityModel.routes.isEmpty {
                    VStack(spacing: 10) {
                        Image(wkt: .cloudError)
                            .font(.system(size: 28))
                            .foregroundColor(.earthMuted)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.earthMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button {
                            Task { await communityModel.load(force: true) }
                        } label: {
                            Label {
                                Text("Retry")
                            } icon: {
                                Image(wkt: .refresh).wktIcon(.inline, tint: .earthGreen)
                            }
                            .font(.caption.bold())
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Color.earthCard)
                            .foregroundColor(.earthGreen)
                            .cornerRadius(8)
                        }
                    }
                    .padding(.vertical, 12)
                } else if communityModel.routes.isEmpty && communityModel.didLoad {
                    Text("No routes shared yet — be the first!")
                        .font(.caption).foregroundColor(.earthMuted)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(communityModel.routes.enumerated()), id: \.element.id) { i, route in
                        CommunityRouteCard(
                            route: Binding(
                                get: { i < communityModel.routes.count ? communityModel.routes[i] : route },
                                set: { if i < communityModel.routes.count { communityModel.routes[i] = $0 } }
                            ),
                            hasVoted: CommunityRouteService.shared.hasVoted(for: route.id),
                            isSaved: savedCommunityIds.contains(route.id.recordName),
                            onWockett: {
                                guard i < communityModel.routes.count,
                                      !CommunityRouteService.shared.hasVoted(for: route.id) else { return }
                                communityModel.routes[i].wocketts += 1
                                CommunityRouteService.shared.markVoted(for: route.id)
                                Task {
                                    do { try await CommunityRouteService.shared.wockett(id: route.id) }
                                    catch { wocketError = "Couldn't save your Wockett — check your connection and try again." }
                                }
                            },
                            onSave: {
                                routeStore.save(CustomRoute(
                                    id: UUID(), name: route.name,
                                    waypoints: route.waypoints,
                                    totalDistance: route.distanceMeters,
                                    isLoop: route.isLoop, createdAt: Date(),
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
                                onNavigateAway?()
                            },
                            onHide: { if i < communityModel.routes.count { communityModel.routes.remove(at: i) } }
                        )
                        .padding(.horizontal, 20)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCommunityRoutes)
        .animation(.easeInOut(duration: 0.2), value: communityModel.loadError != nil)
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
                .background(isSelected ? Color.earthGreenFill : Color.earthCard)
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
                .background(isSelected ? Color.earthGreenFill : Color.earthCard)
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
}

// MARK: - Route Finder View (thin modal wrapper with dismiss chrome)

struct RouteFinderView: View {
    @ObservedObject var routeManager: RouteManager
    @ObservedObject var historyStore: WalkHistoryStore
    @ObservedObject var routeStore: CustomRouteStore
    @ObservedObject var stepManager: StepManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RouteFinderContentView(
            routeManager: routeManager,
            historyStore: historyStore,
            routeStore: routeStore,
            stepManager: stepManager,
            onNavigateAway: { dismiss() },
            onDismiss: { dismiss() }
        )
    }
}


// MARK: - WalkIntent persistence helpers

// MARK: - Marker overlay for checkpoint / finish

final class MarkerCircle: MKCircle {
    var isFinish = false
}

/// One section of a trail on the Routes map, tagged with its list row.
final class TrailPolyline: MKPolyline {
    var itemId = ""
    /// The light outline drawn under the green line.
    var isCasing = false
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
    var trails: [TrailListItem] = []
    var selectedTrailID: String?
    /// Tones Apple's base map down so the trail lines carry the screen.
    var mutedBase = false
    /// How much of the map, from the bottom, the panel covers.
    var bottomInset: CGFloat = 440
    /// A tap on or near a trail line, with its list row's id.
    var onTrailTap: ((String) -> Void)?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.overrideUserInterfaceStyle = .unspecified
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)
        if let loc = userLocation {
            context.coordinator.hasSetInitialRegion = true
            let span = max(goalDistanceMeters * 2.5, 1500)
            map.setRegion(MKCoordinateRegion(center: loc, latitudinalMeters: span, longitudinalMeters: span), animated: false)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        if let loc = userLocation, !context.coordinator.hasSetInitialRegion {
            context.coordinator.hasSetInitialRegion = true
            let span = max(goalDistanceMeters * 2.5, 1500)
            map.setRegion(MKCoordinateRegion(center: loc, latitudinalMeters: span, longitudinalMeters: span), animated: false)
        }

        let currentIds = routes.map { $0.id }

        if context.coordinator.lastRouteIds != currentIds {
            context.coordinator.lastRouteIds = currentIds
            context.coordinator.lastSelectedId = UUID()  // reset sentinel

            map.removeOverlays(map.overlays.filter { ($0 is MKPolyline && !($0 is TrailPolyline)) || $0 is MarkerCircle })

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

            map.removeOverlays(map.overlays.filter { $0 is MarkerCircle })
            if let sel = selectedRoute {
                for fraction in [0.25, 0.5, 0.75] {
                    if let c = sel.polyline.coordinate(atFraction: fraction) {
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

        updateTrails(on: map, context: context)
    }

    // MARK: Trails

    private func updateTrails(on map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.lastMutedBase != mutedBase {
            coordinator.lastMutedBase = mutedBase
            map.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: mutedBase ? .muted : .default)
        }

        let ids = trails.map(\.id)
        if coordinator.lastTrailIds != ids {
            coordinator.lastTrailIds = ids
            coordinator.lastSelectedTrailId = ""  // force a restyle below
            map.removeOverlays(map.overlays.filter { $0 is TrailPolyline })
            // Each section is drawn twice: a light casing under a green line.
            // The casing separates the trail from Apple's own path drawing,
            // which comes from different data and can sit tens of metres away
            // (OSM vs Apple, 2026-09-24 — the pack itself matches OSM to
            // 0.6 m). Every casing goes in before any line: added pairwise,
            // a later section's casing cut white gaps into the line it met.
            for isCasing in [true, false] {
                for item in trails {
                    for coords in item.polylines where coords.count > 1 {
                        let line = TrailPolyline(coordinates: coords, count: coords.count)
                        line.itemId = item.id
                        line.isCasing = isCasing
                        map.addOverlay(line, level: .aboveRoads)
                    }
                }
            }
            // A new list (opening Trails, a filter, a new location) frames the
            // nearest rows and the person above the panel. Without this the
            // map stayed where it opened, centred on the user and therefore
            // behind the panel, so a filter's results could all be off screen.
            if selectedTrailID == nil, !trails.isEmpty {
                coordinator.regionBeforeTrail = nil
                var rect = trails.prefix(Self.framedTrailCount).flatMap { $0.polylines.joined() }
                    .reduce(MKMapRect.null) { r, c in
                        let p = MKMapPoint(c)
                        return r.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                    }
                if let user = userLocation {
                    let p = MKMapPoint(user)
                    rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
                if !rect.isNull {
                    map.setVisibleMapRect(rect,
                                          edgePadding: UIEdgeInsets(top: 70, left: 36, bottom: bottomInset + 28, right: 36),
                                          animated: true)
                }
            }
        }

        let previous = coordinator.lastSelectedTrailId
        guard previous != selectedTrailID else { return }
        coordinator.lastSelectedTrailId = selectedTrailID
        for overlay in map.overlays {
            guard let line = overlay as? TrailPolyline,
                  let renderer = map.renderer(for: line) as? MKPolylineRenderer else { continue }
            Self.style(renderer, for: line, selectedId: selectedTrailID)
            renderer.setNeedsDisplay()
        }

        if let id = selectedTrailID, let item = trails.first(where: { $0.id == id }) {
            // Remember where the person was, so Back returns there.
            if coordinator.regionBeforeTrail == nil { coordinator.regionBeforeTrail = map.region }
            let rect = item.polylines.joined().reduce(MKMapRect.null) { r, c in
                let p = MKMapPoint(c)
                return r.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
            }
            if !rect.isNull {
                // Frame the trail in what the panel leaves visible. A fixed
                // 480 pt cut a 1.1 mi loop off at the top (Joe, 2026-09-24).
                map.setVisibleMapRect(rect,
                                      edgePadding: UIEdgeInsets(top: 70, left: 36, bottom: bottomInset + 28, right: 36),
                                      animated: true)
            }
        } else if selectedTrailID == nil, let region = coordinator.regionBeforeTrail {
            coordinator.regionBeforeTrail = nil
            map.setRegion(region, animated: true)
        }
    }

    /// How many of the nearest list rows a new list frames on the map.
    static let framedTrailCount = 5

    static func style(_ renderer: MKPolylineRenderer, for line: TrailPolyline, selectedId: String?) {
        let isSelected = line.itemId == selectedId
        let isDimmed = selectedId != nil && !isSelected
        renderer.lineCap = .round
        renderer.lineJoin = .round
        if line.isCasing {
            renderer.strokeColor = .systemBackground
            renderer.lineWidth = isSelected ? 9 : 6
            renderer.alpha = isDimmed ? 0 : 0.9
        } else {
            renderer.strokeColor = .brandGreen
            renderer.lineWidth = isSelected ? 5 : 3
            renderer.alpha = isDimmed ? 0.3 : 1.0
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RouteFinderMapView
        var lastRouteIds: [UUID] = []
        var lastSelectedId: UUID? = UUID()
        var lastTrailIds: [String] = []
        var lastSelectedTrailId: String? = ""
        var lastMutedBase = false
        var regionBeforeTrail: MKCoordinateRegion?
        var hasSetInitialRegion = false
        init(_ p: RouteFinderMapView) { parent = p }

        /// Selects the trail whose line passes within a fingertip of the tap.
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MKMapView, let onTrailTap = parent.onTrailTap else { return }
            let tap = gesture.location(in: map)
            let reach: CGFloat = 22
            var best: (id: String, distance: CGFloat)?
            for case let line as TrailPolyline in map.overlays where !line.isCasing {
                let box = map.convert(MKCoordinateRegion(line.boundingMapRect), toRectTo: map).insetBy(dx: -reach, dy: -reach)
                guard box.contains(tap) else { continue }
                let points = line.points()
                var previous: CGPoint?
                for i in 0..<line.pointCount {
                    let point = map.convert(points[i].coordinate, toPointTo: map)
                    if let previous {
                        let d = Self.distance(from: tap, toSegment: previous, point)
                        if d <= reach, d < (best?.distance ?? .infinity) { best = (line.itemId, d) }
                    }
                    previous = point
                }
            }
            if let best { onTrailTap(best.id) }
        }

        private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? TrailPolyline {
                let r = MKPolylineRenderer(polyline: line)
                RouteFinderMapView.style(r, for: line, selectedId: parent.selectedTrailID)
                return r
            }
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
