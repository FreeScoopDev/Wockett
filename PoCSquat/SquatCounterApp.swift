import SwiftUI
import SwiftData
import TipKit
import BackgroundTasks
import UserNotifications

// MARK: - UI Test Detection

#if DEBUG
let isWKTUITestMode = ProcessInfo.processInfo.arguments.contains("-WKTUITest")
#else
let isWKTUITestMode = false
#endif

// MARK: - App Entry Point

@main
struct SquatCounterApp: App {
    private let container = AppModelContainer.shared
    @StateObject private var petStore:     PetStore
    @StateObject private var stepManager:  StepManager
    @StateObject private var routeManager: RouteManager
    @StateObject private var routeStore:   CustomRouteStore
    @StateObject private var historyStore: WalkHistoryStore
    @StateObject private var tabRouter:    TabRouter
    @State private var communityRoutesModel = CommunityRoutesModel()
    @State private var showSplash = !isWKTUITestMode

    init() {
        BackgroundTaskManager.shared.registerTasks()
        UNUserNotificationCenter.current().delegate = AppNotificationDelegate.shared
        try? Tips.configure([.displayFrequency(.weekly), .datastoreLocation(.applicationDefault)])
        // Construct all shared stores before @StateObject wraps them — same pattern as PetStore.
        _petStore     = StateObject(wrappedValue: PetStore(context: AppModelContainer.shared.mainContext))
        _stepManager  = StateObject(wrappedValue: StepManager())
        _routeManager = StateObject(wrappedValue: RouteManager())
        _routeStore   = StateObject(wrappedValue: CustomRouteStore())
        _historyStore = StateObject(wrappedValue: WalkHistoryStore())
        _tabRouter    = StateObject(wrappedValue: TabRouter())
        #if DEBUG
        if isWKTUITestMode { UIView.setAnimationsEnabled(false) }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                TabView(selection: $tabRouter.selected) {
                    Tab(value: AppTab.health) {
                        NavigationStack {
                            HealthHubView()
                        }
                    } label: {
                        Label { Text("Health") } icon: { Image(wkt: .health) }
                    }
                    .accessibilityIdentifier("tab.health")
                    Tab(value: AppTab.routes) {
                        NavigationStack {
                            RouteFinderContentView(
                                routeManager: routeManager,
                                historyStore: historyStore,
                                routeStore: routeStore,
                                stepManager: stepManager,
                                onNavigateAway: {
                                    ActiveWalkStore.shared.requestReopen()
                                    tabRouter.selected = .home
                                }
                            )
                        }
                    } label: {
                        Label { Text("Routes") } icon: { Image(wkt: .routes) }
                    }
                    .accessibilityIdentifier("tab.routes")
                    Tab("Home", image: "wkt.home.pin", value: AppTab.home) {
                        NavigationStack {
                            StepCounterView()
                        }
                    }
                    .accessibilityIdentifier("tab.home")
                    Tab(value: AppTab.community) {
                        NavigationStack {
                            CommunityHubView()
                        }
                    } label: {
                        Label { Text("Community") } icon: { Image(wkt: .community) }
                    }
                    .accessibilityIdentifier("tab.community")
                    Tab(value: AppTab.settings) {
                        NavigationStack {
                            SettingsView()
                        }
                    } label: {
                        Label { Text("Settings") } icon: { Image(wkt: .settings) }
                    }
                    .accessibilityIdentifier("tab.settings")
                }
                // Bottom tab bar on iPhone; top tab bar / sidebar on iPad.
                .tabViewStyle(.sidebarAdaptable)
                // Tab bar collapses on downward scroll (iPhone only; ignored on iPad).
                .tabBarMinimizeBehavior(.onScrollDown)
                // Cap Dynamic Type at Accessibility 2 so tiles and tab bar remain usable.
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                // Active walk tile; isEnabled:false completely hides the capsule when idle.
                .tabViewBottomAccessory(isEnabled: ActiveWalkStore.shared.isActive) {
                    ActiveMiniTileContainer()
                }
                .tint(.earthGreen)

                // Splash renders on top from the very first frame — no system presentation
                // delay, so the dashboard is never visible before it. showSplash starts true
                // on cold launch; @State persists across background/foreground, so the splash
                // never re-appears when the user returns to an already-open app.
                if showSplash {
                    SplashView { showSplash = false }
                        .ignoresSafeArea()
                        .zIndex(1)
                }
            }
            .environment(ActiveWalkStore.shared)
            .environment(communityRoutesModel)
            .environmentObject(petStore)
            .environmentObject(stepManager)
            .environmentObject(routeManager)
            .environmentObject(routeStore)
            .environmentObject(historyStore)
            .environmentObject(tabRouter)
            .onChange(of: NotificationService.shared.pendingAction) { _, action in
                // "Start Walk" on a streak or pet nudge: land on Home, and if a
                // session is already running, reopen it instead of starting over.
                guard action == NotificationAction.startWalk,
                      NotificationService.shared.consumePendingAction() != nil else { return }
                tabRouter.selected = .home
                if ActiveWalkStore.shared.isActive { ActiveWalkStore.shared.requestReopen() }
            }
            .modelContainer(container)
            .task {
                // Boot ordering: configure + salvage run synchronously (no suspension)
                // before the Live Activity reap, so the reap and Home's
                // hasRestorableWalk check both see consistent session state.
                ActiveWalkStore.shared.configure(historyStore: historyStore)
                ActiveWalkStore.shared.salvageStaleWalkIfNeeded()
                if ActiveWalkStore.shared.session == nil {
                    await WalkLiveActivityManager.shared.endAllActivities()
                }
                #if DEBUG
                if isWKTUITestMode {
                    DevSeedStore.seedScreenshotDemo(history: historyStore, pets: petStore, routes: routeStore)
                    return
                }
                #endif
                ActivityDetectionService.shared.startDetection()
                NotificationService.shared.registerCategories()
                // Quiet delivery, once, only if never asked. The real prompt is Settings' job.
                await NotificationService.shared.requestQuietDeliveryIfNeverAsked()
                await scheduleWeeklySummaryNotification()
            }
        }
    }

    // Moved from StepCounterView so it runs once at launch, not on every Home tab appear.
    @MainActor
    private func scheduleWeeklySummaryNotification() async {
        let sessions = historyStore.sessions
        let streak   = StreakStore.shared.currentStreak

        let cal        = Calendar.current
        let weekStart  = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) ?? Date()
        let weekSessions = sessions.filter { $0.date >= weekStart }
        let weekSteps  = weekSessions.reduce(0)   { $0 + $1.estimatedSteps }
        let weekKm     = weekSessions.reduce(0.0) { $0 + $1.totalDistance } / 1000

        let body: String
        if weekSteps > 0 {
            let streakSuffix = streak > 0 ? " · \(streak)-day streak 🔥" : ""
            body = "This week: \(weekSteps.formatted()) steps · \(String(format: "%.1f", weekKm)) km\(streakSuffix). Keep it up!"
        } else {
            body = "A new week starts today — lace up and start strong! 💪"
        }

        var comps      = DateComponents()
        comps.weekday  = 1; comps.hour = 20; comps.minute = 0
        let trigger    = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        await NotificationService.shared.schedule(.weeklySummary, title: "Your week in review 📊", body: body, trigger: trigger)
    }
}


