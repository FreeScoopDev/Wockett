import SwiftUI
import MapKit

// MARK: - Step Counter View

struct StepCounterView: View {
    @StateObject private var stepManager  = StepManager()
    @StateObject private var routeManager = RouteManager()
    @StateObject private var routeStore   = CustomRouteStore()
    @StateObject private var historyStore = WalkHistoryStore()

    @EnvironmentObject private var petStore: PetStore

    @State private var showBadges               = false
    @State private var earnedBadge: WalkBadge?  = nil
    @State private var showGoalSheet            = false
    @State private var showMyRoutes             = false
    @State private var showBuildRoute           = false
    @State private var showWalkHistory          = false
    @State private var showPetManagement        = false
    @State private var showRouteFinder          = false
    @State private var routeFinderShowsNearby   = false
    @State private var showUserDetail = false
    @State private var selectedPetForDetail: PetProfile?
    @State private var selectedCalendarDay: CalendarDay?
    @State private var containerWidth: CGFloat = 350
    @State private var calendarWeekOffset: Int = 0
    @State private var showSettings = false
    @State private var showMonthCalendar = false
    @State private var showFreeWalk = false

    var body: some View {
        stepCounterCore
            .sheet(isPresented: $showUserDetail) {
                UserStepDetailSheet(stepManager: stepManager, historyStore: historyStore)
            }
            .sheet(item: $selectedCalendarDay) { day in
                DayDetailSheet(day: day, sessions: historyStore.sessions)
            }
            .sheet(isPresented: $showMonthCalendar) {
                MonthCalendarView(stepManager: stepManager, sessions: historyStore.sessions)
            }
            .sheet(item: $selectedPetForDetail) { pet in
                PetDetailSheet(pet: pet, petStore: petStore, historyStore: historyStore) {
                    selectedPetForDetail = pet
                }
            }
            .sheet(isPresented: $showGoalSheet) { GoalEditorSheet(stepManager: stepManager) }
            .fullScreenCover(isPresented: $showFreeWalk) {
                FreeWalkView(historyStore: historyStore, routeStore: routeStore)
            }
            .fullScreenCover(isPresented: $showRouteFinder) {
                RouteFinderView(
                    routeManager: routeManager,
                    historyStore: historyStore,
                    routeStore: routeStore,
                    stepManager: stepManager,
                    openWithNearby: routeFinderShowsNearby
                )
            }
            .onChange(of: showRouteFinder) { _, isShowing in
                if !isShowing { routeFinderShowsNearby = false }
            }
            .sheet(isPresented: $showBadges) {
                BadgesView(
                    sessions: historyStore.sessions,
                    todaySteps: stepManager.todaySteps,
                    dailyGoal: stepManager.currentGoal
                )
            }
            .fullScreenCover(item: $earnedBadge) { badge in
                BadgeEarnedView(badge: badge)
            }
    }

    // Split into layers so each chunk stays within the Swift type-checker's budget.
    private var stepCounterCore: some View {
        scrollWithDestinations
            .onChange(of: stepManager.currentGoal) { _, _ in clearRoutes() }
            .onChange(of: historyStore.sessions.count) { _, _ in
                Task { await stepManager.refreshWeeklyCalendar(sessions: historyStore.sessions, weekOffset: calendarWeekOffset) }
            }
    }

    private var scrollWithDestinations: some View {
        scrollWithLifecycle
            .navigationDestination(isPresented: $showSettings) { SettingsView(stepManager: stepManager, historyStore: historyStore, routeStore: routeStore) }
            .navigationDestination(isPresented: $showMyRoutes) { CustomRoutesListView(store: routeStore, historyStore: historyStore) }
            .navigationDestination(isPresented: $showBuildRoute) { CustomRouteBuilderView { route in routeStore.save(route) } }
            .navigationDestination(isPresented: $showWalkHistory) { WalkHistoryView(store: historyStore) }
            .navigationDestination(isPresented: $showPetManagement) { PetManagementView(historyStore: historyStore, defaultGoal: stepManager.currentGoal) }
    }

    private var scrollWithLifecycle: some View {
        ScrollViewReader { proxy in mainScrollView(proxy: proxy) }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear").foregroundColor(.earthGreen)
                    }
                }
                ToolbarItem(placement: .principal) { BannerTitleView() }
            }
            .task {
                await stepManager.initialize()
                await stepManager.refreshWeeklyCalendar(sessions: historyStore.sessions, weekOffset: calendarWeekOffset)
            }
            .onChange(of: stepManager.todaySteps) { _, _ in
                Task { await stepManager.refreshWeeklyCalendar(sessions: historyStore.sessions, weekOffset: calendarWeekOffset) }
            }
            .onChange(of: stepManager.tagConfigs) { _, _ in
                Task { await stepManager.refreshWeeklyCalendar(sessions: historyStore.sessions, weekOffset: calendarWeekOffset) }
            }
            .onAppear { handleAppear() }
            .onChange(of: stepManager.todaySteps) { _, steps in handleStepGoalCheck(steps) }
    }

    @ViewBuilder
    private func mainScrollView(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                progressSection.padding(.top, 8)
                actionGrid.padding(.horizontal)
                streakIndicator
                WeeklyCalendarView(
                    days: stepManager.weeklyCalendar,
                    sessions: historyStore.sessions,
                    weekOffset: calendarWeekOffset,
                    onDayTap: { selectedCalendarDay = $0 },
                    onWeekChange: { delta in
                        let newOffset = (calendarWeekOffset + delta).clamped(to: -52...52)
                        guard newOffset != calendarWeekOffset else { return }
                        calendarWeekOffset = newOffset
                        Task { await stepManager.refreshWeeklyCalendar(sessions: historyStore.sessions, weekOffset: newOffset) }
                    },
                    onCalendarTap: { showMonthCalendar = true }
                )
                settingsSection
            }
            .padding(.bottom, 40)
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { containerWidth = geo.size.width }
                }
            )
        }
        .refreshable { await stepManager.refresh() }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.earthBg.ignoresSafeArea())
    }

    private func handleAppear() {
        if calendarWeekOffset != 0 {
            calendarWeekOffset = 0
            Task { await stepManager.refreshWeeklyCalendar(sessions: historyStore.sessions, weekOffset: 0) }
        }
        if let badge = StreakStore.shared.refresh(sessions: historyStore.sessions, todaySteps: stepManager.todaySteps, dailyGoal: stepManager.currentGoal) {
            earnedBadge = badge
        }
    }

    private func handleStepGoalCheck(_ steps: Int) {
        if let badge = StreakStore.shared.refresh(sessions: historyStore.sessions, todaySteps: steps, dailyGoal: stepManager.currentGoal) {
            earnedBadge = badge
        }
    }

    private func clearRoutes() {
        routeManager.suggestedRoutes = []
        routeManager.locationError   = nil
    }

    private var petRowLabel: String {
        let active = petStore.activePets
        if petStore.pets.isEmpty { return "Add a Pet" }
        switch active.count {
        case 0: return "\(petStore.pets.count) \(petStore.pets.count == 1 ? "pet" : "pets")"
        case 1: return "Walking with \(active[0].name)"
        case 2: return "Walking with \(active[0].name) & \(active[1].name)"
        default: return "Walking with \(active.count) pets"
        }
    }

    static func formatDistance(_ meters: Double) -> String {
        let f = MKDistanceFormatter()
        f.unitStyle = .abbreviated
        return f.string(fromDistance: meters)
    }

    // MARK: Progress Ring

    private func userRingView(diameter: CGFloat) -> some View {
        let stroke    = diameter * 18 / 190
        let stepFont  = diameter * 36 / 190
        let goalFont  = diameter * 14 / 190
        let distFont  = diameter * 11 / 190
        let goalNotMet = stepManager.todaySteps < stepManager.currentGoal
        return ZStack {
            Circle()
                .stroke(Color.earthMuted.opacity(0.15), lineWidth: stroke)
            Circle()
                .trim(from: 0, to: stepManager.progress)
                .stroke(
                    LinearGradient(colors: [.earthGreen, .earthOrange], startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: stepManager.progress)
            VStack(spacing: 2) {
                Text(stepManager.todaySteps.formatted())
                    .font(.system(size: stepFont, weight: .bold, design: .rounded))
                    .foregroundColor(.earthCream)
                Text("/ \(stepManager.currentGoal.formatted())")
                    .font(.system(size: goalFont))
                    .foregroundColor(.earthMuted)
                if goalNotMet {
                    Text("~\(Self.formatDistance(stepManager.remainingMeters)) left")
                        .font(.system(size: distFont, weight: .medium))
                        .foregroundColor(.earthOrange.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 1)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .onTapGesture { showUserDetail = true }
    }

    private var progressSection: some View {
        let available  = max(containerWidth - 32, 280)
        let badgeColW: CGFloat = 74
        let petColW:   CGFloat = 64
        let hSpacing:  CGFloat = 14
        let hasPets    = !petStore.activePets.isEmpty
        // Left column: pets (64pt) or phantom spacer equal to badge column (74pt) for symmetry.
        // This keeps the ring centered over the action grid regardless of pet count.
        let leftColW: CGFloat = hasPets ? petColW : badgeColW
        let ringDiam: CGFloat = min(available - leftColW - badgeColW - hSpacing * 2, 260)
        return VStack(spacing: 14) {
            HStack(alignment: .center, spacing: hSpacing) {
                if hasPets {
                    petColumnView.frame(width: petColW)
                } else {
                    Color.clear.frame(width: badgeColW)
                }
                userRingView(diameter: ringDiam)
                badgeColumnView
                    .frame(width: badgeColW)
            }
        }
        .padding(.vertical, 24)
        .padding(.horizontal)
    }

    private var petColumnView: some View {
        VStack(spacing: 10) {
            ForEach(petStore.activePets) { pet in
                smallPetRing(pet: pet)
            }
        }
    }

    private var badgeColumnView: some View {
        let sessions = historyStore.sessions
        let streak   = StreakStore.shared.currentStreak
        let earned   = walkBadges.filter { $0.isEarned(sessions: sessions, currentStreak: streak) }
        let unearned = walkBadges.filter { !$0.isEarned(sessions: sessions, currentStreak: streak) }
        let nextBadge = unearned.max { $0.progress(sessions: sessions, currentStreak: streak) < $1.progress(sessions: sessions, currentStreak: streak) }

        // Up to 2 most recently earned, then fill with the closest-to-earning badge
        var spotlight: [(WalkBadge, Double)] = []
        for badge in earned.suffix(2).reversed() { spotlight.append((badge, 1.0)) }
        if let next = nextBadge, spotlight.count < 3 {
            spotlight.append((next, next.progress(sessions: sessions, currentStreak: streak)))
        }
        if spotlight.isEmpty, let first = walkBadges.first { spotlight.append((first, 0)) }
        let badgeSpotlight = Array(spotlight.prefix(3))

        return Button { showBadges = true } label: {
            VStack(spacing: 10) {
                ForEach(badgeSpotlight.indices, id: \.self) { i in
                    homeBadgeRing(badgeSpotlight[i].0, progress: badgeSpotlight[i].1,
                                  sessions: sessions, streak: streak,
                                  ringSize: 54, lineWidth: 3, emojiSize: 21, labelSize: 9)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func homeBadgeRing(_ badge: WalkBadge, progress: Double, sessions: [WalkSession], streak: Int,
                                ringSize: CGFloat, lineWidth: CGFloat, emojiSize: CGFloat, labelSize: CGFloat) -> some View {
        let earned = progress >= 1.0
        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.earthMuted.opacity(0.15), lineWidth: lineWidth)
                if progress > 0 {
                    Circle()
                        .trim(from: 0, to: min(progress, 1.0))
                        .stroke(
                            earned ? Color.earthGreen : Color.earthOrange,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                Text(badge.emoji)
                    .font(.system(size: emojiSize))
                    .opacity(earned ? 1.0 : 0.55)
            }
            .frame(width: ringSize, height: ringSize)

            Text(badge.name)
                .font(.system(size: labelSize, weight: .semibold))
                .foregroundColor(earned ? .earthCream : .earthMuted)
                .multilineTextAlignment(.center)
                .lineLimit(1)
        }
    }

    private var streakIndicator: some View {
        let streak = StreakStore.shared.currentStreak
        return Button { showBadges = true } label: {
            HStack(spacing: 6) {
                Text(streak > 0 ? "🔥" : "💤")
                    .font(.system(size: 14))
                if streak > 0 {
                    Text("\(streak)-day streak")
                        .font(.caption.bold())
                        .foregroundColor(.earthGreen)
                } else {
                    Text("Start your streak today")
                        .font(.caption)
                        .foregroundColor(.earthMuted)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.earthMuted)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color.earthCard)
            .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }

    private func smallPetRing(pet: PetProfile) -> some View {
        let steps = petStore.todaySteps(for: pet, in: historyStore.sessions)
        let progress = min(1.0, Double(steps) / Double(max(1, pet.goalSteps)))
        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(pet.accentColor.opacity(0.2), lineWidth: 4)
                    .frame(width: 52, height: 52)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(pet.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 52, height: 52)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: progress)
                VStack(spacing: 0) {
                    Text(pet.displayEmoji).font(.system(size: 18))
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundColor(.earthMuted)
                }
            }
            Text(pet.name)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.earthMuted)
                .lineLimit(1)
        }
        .frame(width: 60)
        .onTapGesture { selectedPetForDetail = pet }
    }

    // MARK: Settings

    private var settingsSection: some View {
        VStack(spacing: 1) {
            row {
                Text("Daily Goal").foregroundColor(.earthCream)
                Spacer()
                Text("\(stepManager.currentGoal.formatted()) steps").foregroundColor(.earthGreen)
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.earthMuted.opacity(0.6))
            }
            .contentShape(Rectangle())
            .onTapGesture { showGoalSheet = true }

            Button { showMyRoutes = true } label: {
                HStack {
                    Label("Saved Items", systemImage: "bookmark.map").foregroundColor(.earthCream)
                    Spacer()
                    if !routeStore.routes.isEmpty {
                        Text("\(routeStore.routes.count)")
                            .font(.caption).foregroundColor(.earthGreen).padding(.trailing, 4)
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.earthMuted.opacity(0.6))
                }
                .padding(.horizontal, 16).padding(.vertical, 16)
            }

            Button { showWalkHistory = true } label: {
                HStack {
                    Label("Walk History", systemImage: "clock.arrow.circlepath").foregroundColor(.earthCream)
                    Spacer()
                    if !historyStore.sessions.isEmpty {
                        Text("\(historyStore.sessions.count)")
                            .font(.caption).foregroundColor(.earthGreen).padding(.trailing, 4)
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.earthMuted.opacity(0.6))
                }
                .padding(.horizontal, 16).padding(.vertical, 16)
            }

            Button { showPetManagement = true } label: {
                HStack {
                    Label(petRowLabel, systemImage: petStore.activePets.isEmpty ? "pawprint" : "pawprint.fill")
                        .foregroundColor(petStore.pets.isEmpty ? .earthCream : .earthGreen)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.earthMuted.opacity(0.6))
                }
                .padding(.horizontal, 16).padding(.vertical, 16)
            }
        }
        .background(Color.earthCard)
        .cornerRadius(16)
        .padding(.horizontal)
    }

    // MARK: Action Grid

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            actionTile(icon: "figure.walk", label: "Start Walking",
                       color: Color.earthGreen) { showFreeWalk = true }

            actionTile(icon: "map.fill", label: "Recommend",
                       color: Color(red: 0.13, green: 0.57, blue: 0.64)) {
                routeFinderShowsNearby = false
                showRouteFinder = true
            }

            actionTile(icon: "sparkles", label: "Explore",
                       color: Color.earthOrange) {
                routeFinderShowsNearby = true
                showRouteFinder = true
            }

            actionTile(icon: "plus.circle.fill", label: "Build Route",
                       color: Color(red: 0.28, green: 0.49, blue: 0.84)) { showBuildRoute = true }
        }
    }

    private func actionTile(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .medium))
                    .frame(height: 28)
                Text(label)
                    .font(.subheadline.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(color)
            .cornerRadius(16)
        }
        .buttonStyle(BounceButtonStyle())
    }

    private func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack { content() }
            .padding(.horizontal, 16).padding(.vertical, 16)
            .overlay(Rectangle().frame(height: 0.5).foregroundColor(Color.earthMuted.opacity(0.2)), alignment: .bottom)
    }
}

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
