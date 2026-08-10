import SwiftUI
import FirebaseCore
import FirebaseCrashlytics

@main
struct SquatCounterApp: App {
    @StateObject private var petStore = PetStore()
    @State private var showSplash = true

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                StepCounterView()
            }
            .environmentObject(petStore)
            .fullScreenCover(isPresented: $showSplash) {
                SplashView { showSplash = false }
            }
        }
    }
}
