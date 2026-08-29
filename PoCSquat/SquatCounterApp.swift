import SwiftUI
import SwiftData
import TipKit
import BackgroundTasks

@main
struct SquatCounterApp: App {
    private let container = AppModelContainer.shared
    @StateObject private var petStore: PetStore
    @State private var showSplash = true

    init() {
        BackgroundTaskManager.shared.registerTasks()
        UNUserNotificationCenter.current().delegate = AppNotificationDelegate.shared
        UNUserNotificationCenter.registerActionCategories()
        try? Tips.configure([.displayFrequency(.weekly), .datastoreLocation(.applicationDefault)])
        // PetStore needs the main context — construct before @StateObject wraps it
        let store = PetStore(context: AppModelContainer.shared.mainContext)
        _petStore = StateObject(wrappedValue: store)
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
            .modelContainer(container)
        }
    }
}
