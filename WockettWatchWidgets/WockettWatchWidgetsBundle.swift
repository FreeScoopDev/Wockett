import SwiftUI
import WidgetKit

// The Apple Watch complications and Smart Stack widgets
// (feat/watch-complications): steps against the goal, the pets' steps, and
// a Start launcher. The phone sends the numbers to the Watch app, which
// stores them in the watch's App Group; this extension reads only that
// (it reads no Health data and has no WatchConnectivity of its own).
// Shares DesignSystem.swift, AppGroup.swift, WatchGlance.swift,
// WatchWalkLink.swift and WockettWatch/WatchSymbols.swift by membership.

@main
struct WockettWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StepsComplication()
        PetsComplication()
        StartComplication()
    }
}
