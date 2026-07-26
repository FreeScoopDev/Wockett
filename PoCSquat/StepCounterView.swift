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
    @State private var freeWalkMode: ActivityMode = .walking
    @State private var rollingBadgePhase: Int = 0
    @AppStorage("pinnedBadgeIds_v1") private var pinnedBadgeIdsStr: String = ""

    private var pinnedBadgeIds: [String] {
        pinnedBadgeIdsStr.isEmpty ? [] : pinnedBadgeIdsStr.split(separator: ",").map(String.init)
    }

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
                FreeWalkView(historyStore: historyStore, routeStore: routeStore, activityMode: freeWalkMode)
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
                    dailyGoal: stepManager.currentGoal,
                    pinnedBadgeIdsStr: $pinnedBadgeIdsStr
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
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_500_000_000)
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        rollingBadgePhase += 1
                    }
                }
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
                communityRoutesCard
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

        // Pinned badges fill fixed slots first, then fill with recently earned
        let pinnedIds = pinnedBadgeIds
        let pinned    = pinnedIds.compactMap { id in walkBadges.first { $0.id == id } }
        let fixedBadges: [(WalkBadge, Double)] = {
            var result: [WalkBadge] = pinned
            for badge in earned.reversed() where !pinnedIds.contains(badge.id) && result.count < 2 {
                result.append(badge)
            }
            return result.prefix(2).map { ($0, 1.0) }
        }()

        // Rolling slot cycles through unearned badges
        let rollingBadge: WalkBadge? = unearned.isEmpty ? nil : unearned[rollingBadgePhase % unearned.count]

        return Button { showBadges = true } label: {
            VStack(spacing: 10) {
                ForEach(fixedBadges, id: \.0.id) { badge, _ in
                    homeBadgeRing(badge, progress: 1.0, sessions: sessions, streak: streak,
                                  ringSize: 54, lineWidth: 3, emojiSize: 21, labelSize: 9,
                                  isPinned: pinnedIds.contains(badge.id))
                }
                // Rolling slot — clips so the slide-in/out stays in bounds
                ZStack {
                    if let badge = rollingBadge {
                        homeBadgeRing(badge,
                                      progress: badge.progress(sessions: sessions, currentStreak: streak),
                                      sessions: sessions, streak: streak,
                                      ringSize: 54, lineWidth: 3, emojiSize: 21, labelSize: 9)
                            .id(badge.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal:   .move(edge: .top).combined(with: .opacity)
                            ))
                    } else if fixedBadges.isEmpty, let first = walkBadges.first {
                        homeBadgeRing(first, progress: 0, sessions: sessions, streak: streak,
                                      ringSize: 54, lineWidth: 3, emojiSize: 21, labelSize: 9)
                    }
                }
                .frame(height: 78)
                .clipped()
            }
        }
        .buttonStyle(.plain)
    }

    private func homeBadgeRing(_ badge: WalkBadge, progress: Double, sessions: [WalkSession], streak: Int,
                                ringSize: CGFloat, lineWidth: CGFloat, emojiSize: CGFloat, labelSize: CGFloat,
                                isPinned: Bool = false) -> some View {
        let earned = progress >= 1.0
        return VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
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

                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.earthOrange)
                        .offset(x: 2, y: -2)
                }
            }

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
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(streak)-day streak")
                            .font(.caption.bold())
                            .foregroundColor(.earthGreen)
                        Text(nextStreakMilestone(for: streak))
                            .font(.system(size: 9))
                            .foregroundColor(.earthMuted)
                    }
                } else {
                    Text("Walk today — earn your first badge")
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

    private func nextStreakMilestone(for streak: Int) -> String {
        let milestones = [7, 30, 100]
        for m in milestones {
            if streak < m {
                let remaining = m - streak
                return "\(remaining) more day\(remaining == 1 ? "" : "s") to \(m)-day badge"
            }
        }
        return "Century walker — legendary!"
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
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            settingsTile(icon: "target", label: "Daily Goal",
                         detail: "\(stepManager.currentGoal.formatted()) steps",
                         color: .earthGreen) { showGoalSheet = true }

            settingsTile(icon: "bookmark.map", label: "Saved Routes",
                         detail: routeStore.routes.isEmpty ? "No routes saved" : "\(routeStore.routes.count) route\(routeStore.routes.count == 1 ? "" : "s")",
                         color: Color(red: 0.28, green: 0.49, blue: 0.84)) { showMyRoutes = true }

            settingsTile(icon: "clock.arrow.circlepath", label: "Walk History",
                         detail: historyStore.sessions.isEmpty ? "No walks yet" : "\(historyStore.sessions.count) walk\(historyStore.sessions.count == 1 ? "" : "s")",
                         color: .earthOrange) { showWalkHistory = true }

            settingsTile(icon: petStore.activePets.isEmpty ? "pawprint" : "pawprint.fill",
                         label: "My Pets",
                         detail: petStore.pets.isEmpty ? "No pets added" : petRowLabel,
                         color: Color(red: 0.73, green: 0.45, blue: 0.27)) { showPetManagement = true }
        }
        .padding(.horizontal)
    }

    private func settingsTile(icon: String, label: String, detail: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(color)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.earthMuted.opacity(0.5))
                }
                Text(label)
                    .font(.subheadline.bold())
                    .foregroundColor(.earthCream)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.earthMuted)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.earthCard)
            .cornerRadius(16)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.97))
    }

    private var communityRoutesCard: some View {
        Button {
            routeFinderShowsNearby = false
            showRouteFinder = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: 0.13, green: 0.57, blue: 0.64).opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "person.2.wave.2")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Color(red: 0.13, green: 0.57, blue: 0.64))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Community Routes")
                        .font(.subheadline.bold())
                        .foregroundColor(.earthCream)
                    Text("Discover walks shared by other users")
                        .font(.caption)
                        .foregroundColor(.earthMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.earthMuted.opacity(0.6))
            }
            .padding(14)
            .background(Color.earthCard)
            .cornerRadius(16)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.98))
        .padding(.horizontal)
    }

    // MARK: Action Grid

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            startActivityTile

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

    private var startActivityTile: some View {
        let isCycling = freeWalkMode == .cycling
        let tileColor: Color = isCycling ? Color(red: 0.13, green: 0.57, blue: 0.64) : Color.earthGreen
        return Button { showFreeWalk = true } label: {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 10) {
                    Image(systemName: freeWalkMode.icon)
                        .font(.system(size: 26, weight: .medium))
                        .frame(height: 28)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: freeWalkMode)
                    Text(isCycling ? "Start Biking" : "Start Walking")
                        .font(.subheadline.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .animation(.spring(response: 0.3), value: freeWalkMode)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 96)

                // Folded corner — tap to toggle between walk and bike
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        freeWalkMode = isCycling ? .walking : .cycling
                    }
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        CornerFoldShape()
                            .fill(Color.black.opacity(0.22))
                            .frame(width: 44, height: 44)
                        Image(systemName: isCycling ? "figure.walk" : "bicycle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(6)
                    }
                }
                .buttonStyle(.plain)
            }
            .background(tileColor.animation(.spring(response: 0.35), value: freeWalkMode))
            .cornerRadius(16)
        }
        .buttonStyle(BounceButtonStyle())
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
