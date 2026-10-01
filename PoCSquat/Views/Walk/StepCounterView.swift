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
    @State private var showWeatherDetail = false
    @State private var heroQuote = BannerStore.shared.randomQuote()

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
            .sheet(isPresented: $showWeatherDetail) {
                if let weather = weatherLocator.weather {
                    HomeWeatherDetailSheet(weather: weather)
                }
            }
            .fullScreenCover(isPresented: $showStationary) {
                StationaryWalkView(historyStore: historyStore, dailyGoal: stepManager.currentGoal)
            }
            .onChange(of: showMyRoutes) { _, isShowing in
                if !isShowing && walkStore.isActive { showResumeWalk = true }
            }
            .fullScreenCover(item: $earnedBadge, onDismiss: {
                ReviewPrompter.shared.noteHighlight()
            }) { badge in
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
            .onChange(of: tabRouter.pendingWalkStart) { _, mode in
                if let mode { startWalkFromIntent(mode) }
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
            // The hero card's "Today" is the screen's title; an empty bar
            // above it would only push the content down.
            .toolbar(.hidden, for: .navigationBar)
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
            VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                heroCard
                if ActivityDetectionService.shared.showWalkSuggestion {
                    activitySuggestion
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                activitySection
                routesSection
                weekSection
            }
            .padding(.horizontal, WktSpacing.screen)
            .padding(.top, 8)
            // The ScrollView already stops its content above the tab bar;
            // this is breathing room under the last card, not an inset.
            .padding(.bottom, WktSpacing.betweenSections)
        }
        .refreshable { await stepManager.refresh() }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.earthBg.ignoresSafeArea())
    }

    /// A walk Siri or the Control Center button asked for (see
    /// `WalkIntentInbox`): the same screen the mode tile opens.
    private func startWalkFromIntent(_ mode: ActivityMode) {
        tabRouter.pendingWalkStart = nil
        if mode == .stationary {
            showStationary = true
        } else {
            freeWalkMode = mode
            showFreeWalk = true
        }
    }

    private func handleAppear() {
        // The App may have consumed the intent before this view existed.
        if let mode = tabRouter.pendingWalkStart { startWalkFromIntent(mode) }
        // A UI test that terminates the app mid-session leaves a checkpoint behind,
        // so the NEXT test launches into the "Resume Your Activity?" alert, which is
        // modal and blocks the tab bar. Discard the checkpoint instead of prompting
        // so every test starts from the same clean state. Release builds are
        // unaffected (isWKTUITestMode is compiled out).
        if isWKTUITestMode {
            walkStore.declineRestore()
        } else if walkStore.hasRestorableWalk {
            showRestoreWalkPrompt = true
        }
        // The badge celebration is a fullScreenCover, so it covers the tab bar and
        // every tab root while it is up. Under UI tests the seeded demo history
        // immediately awards "First Steps", which blocked every navigation test
        // roughly 15 s into the run. Keep refresh() running so streak bookkeeping
        // is identical; only suppress the presentation. (isWKTUITestMode is
        // compiled out of release builds, so shipping behaviour is unchanged.)
        if let badge = streakStore.refresh(sessions: historyStore.sessions, todaySteps: stepManager.todaySteps, dailyGoal: stepManager.currentGoal),
           !isWKTUITestMode {
            earnedBadge = badge
        }
        guard !isWKTUITestMode else { return }
        weatherLocator.fetchIfAuthorized()
    }

    private func handleStepGoalCheck(_ steps: Int) {
        // Same reasoning as handleAppear: never present the celebration cover
        // during a UI test run.
        if let badge = streakStore.refresh(sessions: historyStore.sessions, todaySteps: steps, dailyGoal: stepManager.currentGoal),
           !isWKTUITestMode {
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

    // RouteManager's published status, not a fresh CLLocationManager: this is
    // read on every Home render, and `authorizationStatus` on a new manager is a
    // synchronous call to locationd on the main thread.
    private var gpsIsReady: Bool {
        let status = routeManager.authStatus
        return status == .authorizedAlways || status == .authorizedWhenInUse
    }

    // MARK: Hero

    private var heroCard: some View {
        HomeHeroCard(
            steps: stepManager.todaySteps,
            goal: stepManager.currentGoal,
            progress: stepManager.progress,
            remainingText: stepManager.todaySteps < stepManager.currentGoal
                ? "\(Self.formatDistance(stepManager.remainingMeters)) to go"
                : nil,
            streak: streakStore.currentStreak,
            quote: heroQuote,
            crew: petStore.activePets.map { pet in
                let steps = petStore.todaySteps(for: pet, in: historyStore.sessions)
                return HomeCrewMember(id: pet.id, name: pet.name,
                             progress: min(1, Double(steps) / Double(max(1, pet.goalSteps))))
            },
            onStepsTap: { showUserDetail = true },
            onPetTap: { id in selectedPetForDetail = petStore.activePets.first { $0.id == id } },
            onManageCrew: { showPetManagement = true },
            onStreakTap: {
                tabRouter.pendingCommunityDestination = .badges
                tabRouter.selected = .community
            },
            chips: {
                WktStatusChip(
                    text: gpsIsReady ? "GPS" : "Location off",
                    dot: gpsIsReady ? .earthGreen : .earthMuted,
                    textColor: gpsIsReady ? .earthCream : .earthMuted
                )
                .accessibilityLabel(gpsIsReady ? "GPS ready" : "Location off")
                HomeWeatherStatusChip(locator: weatherLocator) { showWeatherDetail = true }
            }
        )
    }

    // MARK: Start an activity

    private var activitySection: some View {
        WktSection(title: "Start an activity") {
            HomeActivityPicker(selection: $freeWalkMode)
            WktPrimaryButton(title: "Start \(freeWalkMode.sessionLabel)", symbol: .play) {
                if freeWalkMode == .stationary {
                    showStationary = true
                } else {
                    showFreeWalk = true
                }
            }
            .accessibilityIdentifier("home.start")
        }
    }

    // MARK: Routes

    private var routesSection: some View {
        WktSection(title: "Routes", actionTitle: "See all", action: { tabRouter.selected = .routes }, content: {
            HStack(spacing: WktSpacing.betweenCards) {
                routeCard(symbol: .routes, tint: .earthGreen,
                          title: "Find a Route", subtitle: "Recommended near you") {
                    tabRouter.selected = .routes
                }
                .accessibilityIdentifier("home.findRoute")
                let count = routeStore.routes.count
                routeCard(symbol: .place, tint: .accentInfo,
                          title: "My Routes", subtitle: count == 0 ? "None saved yet" : "\(count) saved") {
                    showMyRoutes = true
                }
                .accessibilityIdentifier("home.myRoutes")
            }
        })
    }

    private func routeCard(symbol: WktSymbol, tint: Color, title: String, subtitle: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                WktIconBadge(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.wktRowTitle)
                        .foregroundColor(.earthCream)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(subtitle)
                        .font(.wktLabel)
                        .foregroundColor(.earthMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .wktCard()
        }
        .buttonStyle(BounceButtonStyle(scale: 0.97))
    }

    // MARK: This week

    private var weekSection: some View {
        WktSection(title: "This week", actionTitle: "Details", action: { tabRouter.selected = .health }, content: {
            HomeWeekCard(days: stepManager.weeklyCalendar)
        })
    }

    private var activitySuggestion: some View {
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
            WktIconBadge(symbol: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text("Looks like you're \(label)")
                    .font(.wktRowTitle)
                    .foregroundColor(.earthCream)
                Text("Want to start tracking?")
                    .font(.wktLabel)
                    .foregroundColor(.earthMuted)
            }
            Spacer()
            WktPillButton(title: "Start", action: onStart)
            Button(action: onDismiss) {
                Image(wkt: .dismiss)
                    .wktIcon(.inline, tint: .earthMuted)
            }
            .accessibilityLabel("Dismiss suggestion")
        }
        .wktCard(padding: 14)
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
