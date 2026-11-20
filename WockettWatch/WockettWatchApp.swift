import SwiftUI

// The Apple Watch app (chore/watch-target, 2026-11-20). A placeholder until
// the walk remote (feat/watch-walk-remote) gives it something to do: it only
// says where walks start. It shares DesignSystem.swift with the iPhone app and
// the widget, and draws the mark from PoCSquat/Design/WockettMark.swift (both
// by target membership, not copies).

@main
struct WockettWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchPlaceholderView()
        }
    }
}
