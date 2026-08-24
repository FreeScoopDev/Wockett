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
            NavigationStack {
                StepCounterView()
            }
            .environmentObject(petStore)
            .modelContainer(container)
            .fullScreenCover(isPresented: $showSplash) {
                SplashView { showSplash = false }
            }
        }
    }
}
