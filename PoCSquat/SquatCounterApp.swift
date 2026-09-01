import SwiftUI
import SwiftData
import TipKit
import BackgroundTasks
import UserNotifications

// MARK: - App Tab

enum AppTab: Int, Hashable {
    case home, health, community, settings
}

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
    @State private var showSplash = true

    init() {
        BackgroundTaskManager.shared.registerTasks()
        UNUserNotificationCenter.current().delegate = AppNotificationDelegate.shared
        UNUserNotificationCenter.registerActionCategories()
        try? Tips.configure([.displayFrequency(.weekly), .datastoreLocation(.applicationDefault)])
        // Construct all shared stores before @StateObject wraps them — same pattern as PetStore.
        _petStore     = StateObject(wrappedValue: PetStore(context: AppModelContainer.shared.mainContext))
        _stepManager  = StateObject(wrappedValue: StepManager())
        _routeManager = StateObject(wrappedValue: RouteManager())
        _routeStore   = StateObject(wrappedValue: CustomRouteStore())
        _historyStore = StateObject(wrappedValue: WalkHistoryStore())
        _tabRouter    = StateObject(wrappedValue: TabRouter())
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                TabView(selection: $tabRouter.selected) {
                    Tab("Home", systemImage: "house", value: AppTab.home) {
                        NavigationStack {
                            StepCounterView()
                        }
                    }
                    Tab("Health", systemImage: "heart.text.square", value: AppTab.health) {
                        NavigationStack {
                            HealthPlaceholderView()
                        }
                    }
                    Tab("Community", systemImage: "person.2", value: AppTab.community) {
                        NavigationStack {
                            CommunityHubView()
                        }
                    }
                    Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                        NavigationStack {
                            SettingsView()
                        }
                    }
                }
                // Tab bar collapses on downward scroll (iPhone only; ignored on iPad).
                .tabBarMinimizeBehavior(.onScrollDown)
                // Active walk tile floats above the tab bar; moves inline when tab bar collapses.
                .tabViewBottomAccessory {
                    ActiveMiniTileContainer()
                }

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
            .modelContainer(container)
            .task {
                // One-shot launch setup. Runs after StepCounterView.handleAppear() because
                // .onAppear is synchronous and .task is async — salvageStaleWalkIfNeeded()
                // has already completed before this body executes.
                if ActiveWalkStore.shared.session == nil {
                    await WalkLiveActivityManager.shared.endAllActivities()
                }
                ActivityDetectionService.shared.startDetection()
                await scheduleWeeklySummaryNotification()
            }
        }
    }

    // Moved from StepCounterView so it runs once at launch, not on every Home tab appear.
    private func scheduleWeeklySummaryNotification() async {
        let center = UNUserNotificationCenter.current()
        let sessions = historyStore.sessions
        let streak   = StreakStore.shared.currentStreak
        let status   = await center.notificationSettings().authorizationStatus
        guard status == .authorized else { return }
        let enabled = UserDefaults.standard.object(forKey: "notif_weeklySummary") as? Bool ?? true
        guard enabled else {
            center.removePendingNotificationRequests(withIdentifiers: ["wkt-weekly-summary"])
            return
        }

        let cal        = Calendar.current
        let weekStart  = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) ?? Date()
        let weekSessions = sessions.filter { $0.date >= weekStart }
        let weekSteps  = weekSessions.reduce(0)   { $0 + $1.estimatedSteps }
        let weekKm     = weekSessions.reduce(0.0) { $0 + $1.totalDistance } / 1000

        let content        = UNMutableNotificationContent()
        content.title      = "Your week in review 📊"
        content.sound      = .default
        if weekSteps > 0 {
            let streakSuffix = streak > 0 ? " · \(streak)-day streak 🔥" : ""
            content.body = "This week: \(weekSteps.formatted()) steps · \(String(format: "%.1f", weekKm)) km\(streakSuffix). Keep it up!"
        } else {
            content.body = "A new week starts today — lace up and start strong! 💪"
        }

        var comps      = DateComponents()
        comps.weekday  = 1; comps.hour = 20; comps.minute = 0
        let trigger    = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.removePendingNotificationRequests(withIdentifiers: ["wkt-weekly-summary"])
        try? await center.add(UNNotificationRequest(identifier: "wkt-weekly-summary",
                                                    content: content, trigger: trigger))
    }
}

// MARK: - Placeholder tabs

private struct HealthPlaceholderView: View {
    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundColor(.earthGreen)
                Text("Health")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.earthCream)
                Text("Coming soon")
                    .font(.subheadline)
                    .foregroundColor(.earthMuted)
            }
        }
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.inline)
    }
}


