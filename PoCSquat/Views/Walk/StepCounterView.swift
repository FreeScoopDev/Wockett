import SwiftUI
import MapKit
import CoreLocation
import UserNotifications
import SwiftData
import UIKit

// MARK: - Step Counter View

struct StepCounterView: View {
    @EnvironmentObject private var stepManager:  StepManager
    @EnvironmentObject private var routeManager: RouteManager
    @EnvironmentObject private var routeStore:   CustomRouteStore
    @EnvironmentObject private var historyStore: WalkHistoryStore

    @EnvironmentObject private var petStore: PetStore
    @EnvironmentObject private var tabRouter: TabRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ActiveWalkStore.self) private var walkStore
    var streakStore: StreakStore = .shared

    @State private var showResumeWalk           = false
    @State private var showRestoreWalkPrompt    = false
    @State private var earnedBadge: WalkBadge?  = nil
    @State private var showGoalSheet            = false
    @State private var showMyRoutes             = false
    @State private var showBuildRoute           = false
    @State private var showPetManagement        = false
    @State private var showRouteFinder          = false
    @State private var routeFinderShowsNearby   = false
    @State private var showUserDetail = false
    @State private var selectedPetForDetail: PetProfile?
    @State private var containerWidth: CGFloat = 350
    @State private var showFreeWalk = false
    @State private var showStationary = false
    @State private var freeWalkMode: ActivityMode = .walking
    @State private var weatherLocator = HomeWeatherLocator()
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
            .sheet(item: $selectedPetForDetail) { pet in
                PetDetailSheet(pet: pet, petStore: petStore, historyStore: historyStore) {
                    selectedPetForDetail = pet
                }
            }
            .sheet(isPresented: $showGoalSheet) { GoalEditorSheet(stepManager: stepManager) }
            .fullScreenCover(isPresented: $showFreeWalk) {
                ActiveSessionView(activityMode: freeWalkMode, historyStore: historyStore, routeStore: routeStore)
            }
            .fullScreenCover(isPresented: $showStationary) {
                StationaryWalkView(historyStore: historyStore, dailyGoal: stepManager.currentGoal)
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
                // When RouteFinderView closes with an active session, jump straight to the walk.
                if !isShowing && walkStore.isActive { showResumeWalk = true }
            }
            .onChange(of: showMyRoutes) { _, isShowing in
                if !isShowing && walkStore.isActive { showResumeWalk = true }
            }
            .fullScreenCover(item: $earnedBadge) { badge in
                BadgeEarnedView(badge: badge)
            }
            .sheet(isPresented: $showResumeWalk) {
                if let route = walkStore.activeRoute {
                    ActiveSessionView(activityMode: route.activityMode, historyStore: historyStore, routeStore: routeStore)
                }
            }
            .alert("Resume Your Activity?", isPresented: $showRestoreWalkPrompt) {
                Button("Resume") {
                    if walkStore.restoreIfNeeded() != nil {
                        showResumeWalk = true
                    }
                }
                Button("Discard", role: .destructive) {
                    walkStore.declineRestore()
                }
            } message: {
                Text("Wockett closed unexpectedly during an active session. Your progress up to the last checkpoint was saved.")
            }
            .onChange(of: walkStore.reopenRequested) { _, requested in
                guard requested else { return }
                walkStore.consumeReopenRequest()
                showResumeWalk = true
            }
    }

    // Split into layers so each chunk stays within the Swift type-checker's budget.
    private var stepCounterCore: some View {
        scrollWithDestinations
            .onChange(of: stepManager.currentGoal) { _, _ in clearRoutes() }
            .onChange(of: historyStore.sessions.count) { _, _ in
                Task {
                    await stepManager.refresh()
                    await stepManager.refreshWeeklyCalendar(sessions: historyStore.sessions, weekOffset: 0)
                }
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
            .navigationDestination(isPresented: $showMyRoutes) { CustomRoutesListView(store: routeStore, historyStore: historyStore) }
            .navigationDestination(isPresented: $showBuildRoute) { CustomRouteBuilderView { route in
                routeStore.save(route)
                UserDefaults.standard.set(true, forKey: "wkt_customRouteCreated")
            } }
            .navigationDestination(isPresented: $showPetManagement) { PetManagementView(historyStore: historyStore, defaultGoal: stepManager.currentGoal) }
    }

    private var scrollWithLifecycle: some View {
        ScrollViewReader { proxy in mainScrollView(proxy: proxy) }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { BannerTitleView() }
            }
            .task {
                await stepManager.initialize()
                await stepManager.refreshWeeklyCalendar(sessions: historyStore.sessions, weekOffset: 0)
                await stepManager.scheduleStreakNudge(currentStreak: streakStore.currentStreak)
                await petStore.schedulePetNudge(sessions: historyStore.sessions)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    ActivityDetectionService.shared.stopDetection()
                } else if phase == .active {
                    ActivityDetectionService.shared.startDetection()
                    Task {
                        await stepManager.scheduleStreakNudge(currentStreak: streakStore.currentStreak)
                        await petStore.schedulePetNudge(sessions: historyStore.sessions)
                    }
                }
            }
            .onChange(of: stepManager.todaySteps) { _, _ in
                Task {
                    await stepManager.refreshWeeklyCalendar(sessions: historyStore.sessions, weekOffset: 0)
                    await stepManager.scheduleStreakNudge(currentStreak: streakStore.currentStreak)
                }
            }
            .onChange(of: stepManager.tagConfigs) { _, _ in
                Task { await stepManager.refreshWeeklyCalendar(sessions: historyStore.sessions, weekOffset: 0) }
            }
            .onAppear { handleAppear() }
            .onChange(of: stepManager.todaySteps) { _, steps in handleStepGoalCheck(steps) }
    }

    @ViewBuilder
    private func mainScrollView(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                activityHeaderRow.padding(.horizontal).padding(.top, 8)
                activityModeRow.padding(.horizontal)
                findRouteTile.padding(.horizontal)
                statCard.padding(.horizontal)
                crewCard.padding(.horizontal)
                JourneyTrackView(
                    progress:    stepManager.progress,
                    avatarEmoji: petStore.activePets.first?.displayEmoji ?? "🚶"
                )
                switch weatherLocator.fetchState {
                case .loaded:
                    if let weather = weatherLocator.weather {
                        HomeWeatherChip(weather: weather)
                            .padding(.horizontal)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                case .denied:
                    WeatherDeniedChip()
                        .padding(.horizontal)
                        .transition(.opacity)
                case .failed:
                    WeatherFailedChip { weatherLocator.retry() }
                        .padding(.horizontal)
                        .transition(.opacity)
                case .idle, .loading:
                    EmptyView()
                }
                if ActivityDetectionService.shared.showWalkSuggestion {
                    ActivitySuggestionBanner(
                        activity: ActivityDetectionService.shared.detectedActivity,
                        onStart: {
                            let mode: ActivityMode
                        switch ActivityDetectionService.shared.detectedActivity {
                        case .cycling: mode = .cycling
                        case .running: mode = .running
                        default:       mode = .walking
                        }
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                ActivityDetectionService.shared.dismissSuggestion()
                            }
                            freeWalkMode = mode
                            showFreeWalk = true
                        },
                        onDismiss: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                ActivityDetectionService.shared.dismissSuggestion()
                            }
                        }
                    )
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                closeTheGapCard
                communityRoutesCard
                achievementFeedCard
                challengesCard
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
        walkStore.configure(historyStore: historyStore)
        walkStore.salvageStaleWalkIfNeeded()
        if walkStore.hasRestorableWalk {
            showRestoreWalkPrompt = true
        }
        if let badge = streakStore.refresh(sessions: historyStore.sessions, todaySteps: stepManager.todaySteps, dailyGoal: stepManager.currentGoal) {
            earnedBadge = badge
        }
        weatherLocator.fetchIfAuthorized()
    }

    private func handleStepGoalCheck(_ steps: Int) {
        if let badge = streakStore.refresh(sessions: historyStore.sessions, todaySteps: steps, dailyGoal: stepManager.currentGoal) {
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
                    .font(.wktDisplay(stepFont))
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


    private var petColumnView: some View {
        VStack(spacing: 10) {
            ForEach(petStore.activePets) { pet in
                smallPetRing(pet: pet)
            }
        }
    }

    private var badgeColumnView: some View {
        let sessions = historyStore.sessions
        let streak   = streakStore.currentStreak
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

        return Button {
            tabRouter.pendingCommunityDestination = .badges
            tabRouter.selected = .community
        } label: {
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
        let streak = streakStore.currentStreak
        return Button {
            tabRouter.pendingCommunityDestination = .badges
            tabRouter.selected = .community
        } label: {
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
        let milestones = [7, 14, 30, 60, 100]
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
        let streak = petStore.walkStreak(for: pet, in: historyStore.sessions)
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
            if streak > 0 {
                Text("🔥 \(streak)")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.earthOrange)
            }
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

            settingsTile(icon: "mappin.and.ellipse", label: "Saved Routes",
                         detail: routeStore.routes.isEmpty ? "No routes saved" : "\(routeStore.routes.count) route\(routeStore.routes.count == 1 ? "" : "s")",
                         color: Color.accentInfo) { showMyRoutes = true }

            settingsTile(icon: "person.3.fill", label: "Community",
                         detail: "Feed & challenges",
                         color: Color.accentRide) {
                tabRouter.selected = .community
            }
        }
        .padding(.horizontal)
    }

    private func settingsTile(icon: String, label: String, detail: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(color)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.earthMuted.opacity(0.5))
                }
                Text(label)
                    .font(.wktHeading(15))
                    .foregroundColor(.earthCream)
                Text(detail)
                    .wktTechnical(9)
                    .foregroundColor(.earthMuted)
                    .textCase(.uppercase)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.earthCard)
            .cornerRadius(16)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.97))
    }

    @ViewBuilder private var closeTheGapCard: some View {
        let remaining = max(0, stepManager.currentGoal - stepManager.todaySteps)
        let walkMinutes = max(5, Int(Double(remaining) * 0.762 / 84))
        if remaining > 500 {
            Button {
                freeWalkMode = .walking
                showFreeWalk = true
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.earthGreen.opacity(0.15))
                            .frame(width: 38, height: 38)
                        Image(systemName: "figure.walk.motion")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.earthGreen)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(remaining.formatted()) steps to go")
                            .font(.wktHeading(15))
                            .foregroundColor(.earthCream)
                        Text("A \(walkMinutes)-min walk closes the gap")
                            .font(.wktBody(12))
                            .foregroundColor(.earthMuted)
                    }
                    Spacer()
                    Text("Go →")
                        .font(.caption.bold())
                        .foregroundColor(.earthGreen)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.earthGreen.opacity(0.15))
                        .cornerRadius(8)
                }
                .padding(14)
                .background(Color.earthCard)
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.earthGreen.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(BounceButtonStyle(scale: 0.98))
            .padding(.horizontal)
        }
    }

    private var communityRoutesCard: some View {
        Button {
            routeFinderShowsNearby = false
            showRouteFinder = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentRide.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Image(systemName: "person.2.wave.2")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color.accentRide)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Community Routes")
                        .font(.wktHeading(15))
                        .foregroundColor(.earthCream)
                    Text("Discover routes shared by other users")
                        .font(.wktBody(12))
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

    private var achievementFeedCard: some View {
        // File-local adaptive constant — this exact orange-red doesn't recur elsewhere.
        let orange = Color(UIColor { tc in tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.93, green: 0.50, blue: 0.38, alpha: 1)
            : UIColor(red: 0.831, green: 0.294, blue: 0.180, alpha: 1) })
        return Button {
            tabRouter.pendingCommunityDestination = .achievementFeed
            tabRouter.selected = .community
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(orange.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Image(systemName: "medal.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Achievement Feed")
                        .font(.wktHeading(15))
                        .foregroundColor(.earthCream)
                    Text("See what badges the community earned")
                        .font(.wktBody(12))
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

    private var challengesCard: some View {
        Button {
            tabRouter.pendingCommunityDestination = .challenges
            tabRouter.selected = .community
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.earthGreen.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.earthGreen)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Challenges")
                        .font(.wktHeading(15))
                        .foregroundColor(.earthCream)
                    Text("Compete with the community")
                        .font(.wktBody(12))
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

    // MARK: Dashboard Hero (v1.10 design system)

    private var gpsIsReady: Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .authorizedAlways || status == .authorizedWhenInUse
    }

    private var activityHeaderRow: some View {
        HStack {
            Text("START AN ACTIVITY")
                .wktTechnical(10)
                .foregroundColor(.earthMuted)
            Spacer()
            Text(gpsIsReady ? "GPS READY" : "LOCATION OFF")
                .wktTechnical(10)
                .foregroundColor(gpsIsReady ? .earthGreen : .earthMuted)
        }
    }

    private var activityModeRow: some View {
        HStack(spacing: 10) {
            ForEach([ActivityMode.walking, .running, .cycling, .stationary], id: \.rawValue) { mode in
                activityModeTile(mode)
            }
        }
    }

    private func activityModeTile(_ mode: ActivityMode) -> some View {
        let isSelected = freeWalkMode == mode
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { freeWalkMode = mode }
            if mode == .stationary {
                showStationary = true
            } else {
                showFreeWalk = true
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: mode.icon)
                    .font(.system(size: 20, weight: .medium))
                Text(mode.sessionLabel)
                    .font(.wktHeading(13))
            }
            .foregroundColor(isSelected ? .white : mode.tileColor)
            .frame(maxWidth: .infinity)
            .frame(height: 78)
            .background(isSelected ? mode.tileFillColor : Color.earthCard)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.earthLine, lineWidth: isSelected ? 0 : 1)
            )
        }
        .buttonStyle(BounceButtonStyle())
    }

    // Distinctly styled (dashed outline, not a solid activity color) so it reads as a
    // different kind of action from the four activity tiles above — route discovery,
    // not activity start. Folds in what used to be separate Recommend/Explore tiles;
    // Build Route already has its own entry point from the Saved Routes list.
    private var findRouteTile: some View {
        Button {
            routeFinderShowsNearby = false
            showRouteFinder = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "map")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.earthGreen)
                Text("Find a Route")
                    .font(.wktHeading(14))
                    .foregroundColor(.earthCream)
                Spacer()
                Text("Recommend · Explore · Community")
                    .wktTechnical(8)
                    .foregroundColor(.earthMuted)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.earthMuted.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(Color.earthCard)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.earthGreen.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
        .buttonStyle(BounceButtonStyle(scale: 0.97))
    }

    // Ring shows % of goal; step count/goal/distance sit beside it; streak (tap → Badges,
    // same destination the old streak pill and badge rail both used to open) anchors the
    // right edge. Consolidates what used to be 3 separate elements (ring, streak pill,
    // rolling badge rail) into one card, matching the mockup's stat card.
    private var statCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.earthMuted.opacity(0.15), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: stepManager.progress)
                    .stroke(
                        LinearGradient(colors: [.earthGreen, .earthOrange], startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: stepManager.progress)
                VStack(spacing: 0) {
                    Text("\(Int((stepManager.progress * 100).rounded()))")
                        .font(.wktDisplay(20))
                        .foregroundColor(.earthCream)
                    Text("PCT")
                        .wktTechnical(8)
                        .foregroundColor(.earthMuted)
                }
            }
            .frame(width: 68, height: 68)
            .onTapGesture { showUserDetail = true }

            VStack(alignment: .leading, spacing: 3) {
                Text(stepManager.todaySteps.formatted())
                    .font(.wktDisplay(26))
                    .foregroundColor(.earthCream)
                Text("OF \(stepManager.currentGoal.formatted()) STEPS")
                    .wktTechnical(9)
                    .foregroundColor(.earthMuted)
                if stepManager.todaySteps < stepManager.currentGoal {
                    Text("\(Self.formatDistance(stepManager.remainingMeters)) to go")
                        .font(.wktBody(12))
                        .foregroundColor(.earthOrange.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .onTapGesture { showUserDetail = true }

            Spacer(minLength: 8)

            Button {
                tabRouter.pendingCommunityDestination = .badges
                tabRouter.selected = .community
            } label: {
                VStack(spacing: 0) {
                    Text("\(streakStore.currentStreak)")
                        .font(.wktDisplay(22))
                        .foregroundColor(.earthOrange)
                    Text("STREAK")
                        .wktTechnical(8)
                        .foregroundColor(.earthMuted)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.earthCard)
        .cornerRadius(18)
    }

    // "The Crew" — pets promoted to their own full-width card with a Manage link,
    // replacing the cramped side column that used to sit next to the ring.
    private var crewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("THE CREW")
                    .wktTechnical(10)
                    .foregroundColor(.earthMuted)
                Spacer()
                Button {
                    showPetManagement = true
                } label: {
                    Text("Manage ›")
                        .font(.wktBody(12))
                        .foregroundColor(.earthGreen)
                }
            }
            HStack(spacing: 14) {
                ForEach(petStore.activePets) { pet in
                    smallPetRing(pet: pet)
                }
                Button {
                    showPetManagement = true
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .strokeBorder(Color.earthMuted.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                                .frame(width: 52, height: 52)
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.earthMuted)
                        }
                        Text("Add")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.earthMuted)
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(Color.earthCard)
        .cornerRadius(18)
    }

}


// MARK: - Activity Suggestion Banner

private struct ActivitySuggestionBanner: View {
    let activity: ActivityDetectionService.DetectedActivity
    let onStart: () -> Void
    let onDismiss: () -> Void

    private var icon: String {
        switch activity {
        case .cycling: return "bicycle"
        case .running: return "figure.run"
        default:       return "figure.walk"
        }
    }
    private var label: String {
        switch activity {
        case .cycling: return "cycling"
        case .running: return "running"
        default:       return "walking"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.earthGreen.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.earthGreen)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Looks like you're \(label)")
                    .font(.wktHeading(15))
                    .foregroundColor(.earthCream)
                Text("Want to start tracking?")
                    .font(.wktBody(12))
                    .foregroundColor(.earthMuted)
            }
            Spacer()
            Button("Start") { onStart() }
                .font(.caption.bold())
                .foregroundColor(.earthGreen)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.earthGreen.opacity(0.15))
                .cornerRadius(8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.earthMuted)
            }
        }
        .padding(14)
        .background(Color.earthCard)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.earthGreen.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Preview

// Mirrors the real environment wiring from SquatCounterApp.swift (ActiveWalkStore.shared +
// a PetStore backed by the app's real SwiftData container) so the canvas renders exactly
// like a live build/run, without needing a full compile each time. Uses the real on-disk
// store, so pets/history you have locally will show up here too.
#Preview("Dashboard") {
    NavigationStack {
        StepCounterView()
    }
    .environment(ActiveWalkStore.shared)
    .environmentObject(PetStore(context: AppModelContainer.shared.mainContext))
    .environmentObject(StepManager())
    .environmentObject(RouteManager())
    .environmentObject(CustomRouteStore())
    .environmentObject(WalkHistoryStore())
}
