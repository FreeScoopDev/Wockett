import Foundation
import WidgetKit

// MARK: - WidgetSnapshot
//
// The one writer of what the step widget shows. `StepManager` writes it on
// every Health read while the app runs; `BackgroundTaskManager` writes it
// from the background refresh. Until 1.14 the refresh wrote `bg_todaySteps`,
// a key the widget never read, so the widget only changed when the app
// itself was opened.

enum WidgetSnapshot {
    struct Values: Equatable {
        let steps: Int
        let distanceMeters: Double
        let goal: Int
        let lastRefresh: Date?
    }

    /// Writes today's numbers where the widget reads them and asks it to
    /// redraw. `goal` is left as it was when nil: `StepManager` owns it and
    /// the background refresh does not know it.
    @discardableResult
    static func write(steps: Int, distanceMeters: Double, goal: Int? = nil,
                      to defaults: UserDefaults? = AppGroup.defaults, now: Date = Date(),
                      reloadWidget: Bool = true) -> Bool {
        guard let defaults else { return false }
        defaults.set(steps,          forKey: AppGroup.WidgetKey.steps)
        defaults.set(distanceMeters, forKey: AppGroup.WidgetKey.distanceMeters)
        if let goal { defaults.set(goal, forKey: AppGroup.WidgetKey.goal) }
        defaults.set(now,            forKey: AppGroup.WidgetKey.lastRefresh)
        if reloadWidget { WidgetCenter.shared.reloadTimelines(ofKind: AppGroup.stepWidgetKind) }
        return true
    }

    /// What the widget will read back. Nil when nothing was ever written.
    static func read(from defaults: UserDefaults? = AppGroup.defaults) -> Values? {
        guard let defaults, defaults.object(forKey: AppGroup.WidgetKey.lastRefresh) != nil else { return nil }
        return Values(steps: defaults.integer(forKey: AppGroup.WidgetKey.steps),
                      distanceMeters: defaults.double(forKey: AppGroup.WidgetKey.distanceMeters),
                      goal: defaults.integer(forKey: AppGroup.WidgetKey.goal),
                      lastRefresh: defaults.object(forKey: AppGroup.WidgetKey.lastRefresh) as? Date)
    }
}
