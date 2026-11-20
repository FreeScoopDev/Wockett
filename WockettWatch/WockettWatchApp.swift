import SwiftUI

// The Apple Watch app: the walk remote (feat/watch-walk-remote). The phone
// owns every session; the watch shows it and pauses, resumes and finishes
// it, and starts one while Wockett is in front on the phone. It shares
// DesignSystem.swift and WatchWalkLink.swift with the iPhone app (the
// widget shares DesignSystem.swift too), and draws the mark from
// PoCSquat/Design/WockettMark.swift, all by target membership, not copies.
//
// It also receives the complications' numbers (feat/watch-complications):
// the phone's glance arrives in the application context, a complication
// update or a reply, and `WatchGlanceStore` keeps it in the watch's App
// Group for the WockettWatchWidgets extension, even while the app is not
// open (the `.watchConnectivity` background task).

@main
struct WockettWatchApp: App {
    @State private var model = WatchSessionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: model)
                .onAppear { model.activate() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.requestState() }
                }
                // The Start launcher on the face: open on the picker only.
                .onOpenURL { url in
                    if WatchWidgetLink.isStart(url) { model.openedFromStartLauncher() }
                }
        }
        .backgroundTask(.watchConnectivity) {
            await model.finishBackgroundDelivery()
        }
    }
}
