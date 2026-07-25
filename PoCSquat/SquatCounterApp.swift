import SwiftUI

@main
struct SquatCounterApp: App {
    @StateObject private var petStore = PetStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(petStore)
        }
    }
}
