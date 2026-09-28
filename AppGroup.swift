import Foundation

// MARK: - App group — the shared half
//
// Compiled into BOTH the app and WocketWidgetExtension, like
// `DesignSystem.swift` and `ProEntitlement.swift`, so the two processes
// cannot disagree about a key. Until 1.14 each side kept its own string
// literals: the background refresh wrote `bg_todaySteps`, the widget read
// `wkt_widget_steps`, and the Siri steps intent read a third place. One
// enum, no drift.

enum AppGroup {
    static let identifier = "group.com.scoops.wockett"

    /// The shared defaults, nil only if the entitlement is missing.
    static var defaults: UserDefaults? { UserDefaults(suiteName: identifier) }

    /// What the step widget shows. Written by `WidgetSnapshot` (app) and
    /// `StreakStore`; read by `WocketWidget`.
    enum WidgetKey {
        static let steps          = "wkt_widget_steps"
        static let goal           = "wkt_widget_goal"
        static let streak         = "wkt_widget_streak"
        static let distanceMeters = "wkt_widget_distanceMeters"
        static let lastRefresh    = "wkt_widget_lastRefresh"
    }

    /// A "start a walk" request from the Control Center button (widget
    /// process), consumed by the app's `WalkIntentInbox`.
    enum IntentKey {
        static let startWalkPending = "intent_startWalkPending"
        static let activityMode     = "intent_activityMode"
        static let postedAt         = "intent_postedAt"
    }

    /// The step widget's kind, for `WidgetCenter.reloadTimelines(ofKind:)`.
    static let stepWidgetKind = "WocketStepWidget"
}
