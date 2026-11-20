// Watch-local SF Symbol names. WktSymbol lives in the iPhone app target, so
// the Watch keeps its own short list, like the widget's `WS`. Views use these
// names; no `systemName:` literals.
enum WS {
    static let iPhone = "iphone"
    static let notReachable = "iphone.slash"
    static let walk = "figure.walk"
    static let run = "figure.run"
    static let ride = "figure.outdoor.cycle"
    static let indoor = "figure.walk.treadmill"
    static let pause = "pause.fill"
    static let resume = "play.fill"
    static let finish = "stop.fill"
    static let done = "checkmark"

    /// The activity's icon, as the iPhone app's `ActivityMode.icon`.
    static func icon(for activity: WatchActivity) -> String {
        switch activity {
        case .walking:    return walk
        case .running:    return run
        case .cycling:    return ride
        case .stationary: return indoor
        }
    }
}
