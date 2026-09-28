import Foundation
import HealthKit
import Observation

// MARK: - WalkIntentInbox
//
// Where "start a walk" requests from outside the app's views wait until the
// app can act on them. Two senders:
//
// - The Siri / Shortcuts intent (`StartWalkIntent`) runs inside the app
//   process, so it posts in memory and the App's `onChange` sees it.
// - The Control Center button (`WocketWidget/WocketWidgetControl.swift`)
//   runs in the widget process, so it writes the app group defaults and the
//   app reads them at launch and whenever it comes to the front.
//
// Both were written in 1.13 and read by nothing, so Siri and Control Center
// only opened the app. A stored request carries the time it was posted and
// is ignored once it is older than `maxAge`: 1.13 left the flag set forever
// after any Control Center tap, and honouring that on the first 1.14 launch
// would start a walk nobody just asked for.

struct WalkIntentRequest: Equatable {
    let mode: ActivityMode
}

@MainActor
@Observable
final class WalkIntentInbox {
    static let shared = WalkIntentInbox()

    /// Keys in the app group. The widget target cannot see this file, so
    /// `WocketWidgetControl.swift` repeats the three strings; keep them equal.
    enum Keys {
        static let pending  = "intent_startWalkPending"
        static let mode     = "intent_activityMode"
        static let postedAt = "intent_postedAt"
    }

    static let appGroup = "group.com.scoops.wockett"

    /// A request older than this is stale: the app it was meant for never
    /// came to the front, or it predates the timestamp (1.13).
    static let maxAge: TimeInterval = 5 * 60

    /// The in-process request. Observable so the App can react while running.
    private(set) var pending: WalkIntentRequest?

    private let store: UserDefaults?
    private let now: () -> Date

    init(store: UserDefaults? = UserDefaults(suiteName: WalkIntentInbox.appGroup),
         now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// The Siri intent, running in this process.
    func post(_ request: WalkIntentRequest) {
        pending = request
    }

    /// Whatever is waiting, from either sender, cleared as it is read.
    func consume() -> WalkIntentRequest? {
        // 1.13's Siri intent wrote its flag to the standard defaults and
        // nothing ever cleared it. Never act on it; just remove it.
        UserDefaults.standard.removeObject(forKey: Keys.pending)

        if let request = pending {
            pending = nil
            clearStored()
            return request
        }
        guard let store, store.bool(forKey: Keys.pending) else { return nil }
        let postedAt = store.object(forKey: Keys.postedAt) as? Date
        let mode = Self.mode(fromIntentValue: store.string(forKey: Keys.mode))
        clearStored()
        guard let postedAt, now().timeIntervalSince(postedAt) <= Self.maxAge else { return nil }
        return WalkIntentRequest(mode: mode)
    }

    private func clearStored() {
        store?.removeObject(forKey: Keys.pending)
        store?.removeObject(forKey: Keys.mode)
        store?.removeObject(forKey: Keys.postedAt)
    }

    /// The intent's mode words map onto the app's modes; "indoor" is the
    /// stationary walk, and anything unrecognised is a plain walk.
    nonisolated static func mode(fromIntentValue raw: String?) -> ActivityMode {
        switch raw {
        case "indoor":  return .stationary
        case let value?: return ActivityMode(rawValue: value) ?? .walking
        case nil:        return .walking
        }
    }
}

// MARK: - SiriStepsAnswer
//
// "How many steps today in Wockett". Health is asked directly, over the same
// 3 AM-to-now day the Home ring uses; when Health is unavailable or not
// authorised the answer falls back to the count last written for the widget,
// but only if that was refreshed today. 1.13 read a key nothing wrote to the
// standard defaults, so Siri always answered 0.

enum SiriStepsAnswer {
    static let appGroup = WalkIntentInbox.appGroup

    /// Today's total from Health, or nil when Health cannot answer.
    static func fromHealth(dayStart: Date, now: Date = Date()) async -> Int? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let store = HKHealthStore()
        let predicate = HKQuery.predicateForSamples(withStart: dayStart, end: now)
        return await withCheckedContinuation { cont in
            let query = HKStatisticsQuery(quantityType: HKQuantityType(.stepCount),
                                          quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, result, _ in
                guard let sum = result?.sumQuantity() else { cont.resume(returning: nil); return }
                cont.resume(returning: Int(sum.doubleValue(for: .count())))
            }
            store.execute(query)
        }
    }

    /// The freshest count the app or its background refresh wrote for the
    /// widget, if either was refreshed today; nil otherwise.
    static func cached(in store: UserDefaults?, now: Date = Date(),
                       calendar: Calendar = .current) -> Int? {
        guard let store else { return nil }
        let candidates: [(steps: Int, refreshed: Date?)] = [
            (store.integer(forKey: "wkt_widget_steps"), store.object(forKey: "wkt_widget_lastRefresh") as? Date),
            (store.integer(forKey: "bg_todaySteps"),    store.object(forKey: "bg_lastRefresh") as? Date)
        ]
        let today = candidates.compactMap { candidate -> (Int, Date)? in
            guard let refreshed = candidate.refreshed,
                  calendar.isDate(refreshed, inSameDayAs: now) else { return nil }
            return (candidate.steps, refreshed)
        }
        return today.max { $0.1 < $1.1 }?.0
    }
}
