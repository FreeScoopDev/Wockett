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
    @State private var showMyRoutes             = false
    @State private var showBuildRoute           = false
    @State private var showPetManagement        = false
    @State private var showUserDetail = false
    @State private var selectedPetForDetail: PetProfile?
    @State private var showFreeWalk = false
    @State private var showStationary = false
    @State private var freeWalkMode: ActivityMode = .walking
    @State private var weatherLocator = HomeWeatherLocator()

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
            .fullScreenCover(isPresented: $showFreeWalk) {
                ActiveSessionView(activityMode: freeWalkMode, historyStore: historyStore, routeStore: routeStore)
            }
            .fullScreenCover(isPresented: $showStationary) {
                StationaryWalkView(historyStore: historyStore, dailyGoal: stepManager.currentGoal)
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
                myRoutesCard.padding(.horizontal)
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
            }
            .padding(.bottom, 40)
        }
        .refreshable { await stepManager.refresh() }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.earthBg.ignoresSafeArea())
    }

    private func handleAppear() {
        if walkStore.hasRestorableWalk {
            showRestoreWalkPrompt = true
        }
        if let badge = streakStore.refresh(sessions: historyStore.sessions, todaySteps: stepManager.todaySteps, dailyGoal: stepManager.currentGoal) {
            earnedBadge = badge
        }
        guard !isWKTUITestMode else { return }
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

    static func formatDistance(_ meters: Double) -> String {
        let f = MKDistanceFormatter()
        f.unitStyle = .abbreviated
        return f.string(fromDistance: meters)
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
                        Image(wkt: .walk)
                            .wktIcon(.row, tint: .earthGreen)
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
        let tileId: String
        switch mode {
        case .walking:    tileId = "home.tile.walk"
        case .running:    tileId = "home.tile.run"
        case .cycling:    tileId = "home.tile.ride"
        case .stationary: tileId = "home.tile.indoor"
        }
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { freeWalkMode = mode }
            if mode == .stationary {
                showStationary = true
            } else {
                showFreeWalk = true
            }
        } label: {
            VStack(spacing: 8) {
                Image(wkt: mode.wktSymbol)
                    .font(.system(size: 20, weight: .semibold))
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
        .accessibilityIdentifier(tileId)
    }

    // Distinctly styled (dashed outline, not a solid activity color) so it reads as a
    // different kind of action from the four activity tiles above — route discovery,
    // not activity start. Folds in what used to be separate Recommend/Explore tiles;
    // Build Route already has its own entry point from the Saved Routes list.
    private var findRouteTile: some View {
        Button {
            tabRouter.selected = .routes
        } label: {
            HStack(spacing: 10) {
                Image(wkt: .routes)
                    .wktIcon(.inline, tint: .earthGreen)
                Text("Find a Route")
                    .font(.wktHeading(14))
                    .foregroundColor(.earthCream)
                Spacer()
                Text("Recommend · Explore · Community")
                    .wktTechnical(8)
                    .foregroundColor(.earthMuted)
                    .lineLimit(1)
                Image(wkt: .chevronRight)
                    .wktIcon(.inline, tint: .earthMuted.opacity(0.6))
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
        .accessibilityIdentifier("home.findRoute")
    }

    private var myRoutesCard: some View {
        Button { showMyRoutes = true } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentInfo.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Image(wkt: .place)
                        .wktIcon(.row, tint: .accentInfo)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("My Routes")
                        .font(.wktHeading(15))
                        .foregroundColor(.earthCream)
                    let count = routeStore.routes.count
                    Text(count == 0 ? "No routes saved yet" : "\(count) saved route\(count == 1 ? "" : "s")")
                        .font(.wktBody(12))
                        .foregroundColor(.earthMuted)
                }
                Spacer()
                Image(wkt: .chevronRight)
                    .wktIcon(.inline, tint: .earthMuted.opacity(0.6))
            }
            .padding(14)
            .background(Color.earthCard)
            .cornerRadius(16)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.98))
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.statCard")
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
                            Image(wkt: .add)
                                .wktIcon(.row, tint: .earthMuted)
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
        .accessibilityIdentifier("home.crewCard")
    }

}


// MARK: - Activity Suggestion Banner

private struct ActivitySuggestionBanner: View {
    let activity: ActivityDetectionService.DetectedActivity
    let onStart: () -> Void
    let onDismiss: () -> Void

    private var icon: WktSymbol {
        switch activity {
        case .cycling: return .ride
        case .running: return .run
        default:       return .walk
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
                Image(wkt: icon)
                    .wktIcon(.row, tint: .earthGreen)
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
                Image(wkt: .dismiss)
                    .wktIcon(.inline, tint: .earthMuted)
            }
            .accessibilityLabel("Dismiss suggestion")
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
