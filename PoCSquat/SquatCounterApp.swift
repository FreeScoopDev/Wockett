import SwiftUI

@main
struct SquatCounterApp: App {
    @StateObject private var petStore = PetStore()
    @State private var showSplash = true

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
