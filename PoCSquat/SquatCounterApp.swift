import SwiftUI
import SwiftData
import TipKit
import BackgroundTasks

@main
struct SquatCounterApp: App {
    private let container = AppModelContainer.shared
    @StateObject private var petStore:     PetStore
    @StateObject private var stepManager:  StepManager
    @StateObject private var routeManager: RouteManager
    @StateObject private var routeStore:   CustomRouteStore
    @StateObject private var historyStore: WalkHistoryStore
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
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                NavigationStack {
                    StepCounterView()
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
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
            .environmentObject(petStore)
            .environmentObject(stepManager)
            .environmentObject(routeManager)
            .environmentObject(routeStore)
            .environmentObject(historyStore)
            .modelContainer(container)
        }
    }
}
