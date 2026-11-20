import Foundation

// MARK: - The Apple Watch walk remote's messages (feat/watch-walk-remote)
//
// Compiled into the iPhone app and the Watch app (a root file, like
// AppGroup.swift), so both sides read and write the same types and no key is
// typed twice. The phone owns every session: the watch sends commands and
// shows the state the phone sends back. Everything the watch decides from
// that state (what to show, when to tap the wrist) lives here too, so the
// app's unit tests cover it; the watch views only draw it.
//
// Foundation only: this file builds for watchOS. `nonisolated` because the
// app target defaults to the main actor and WatchConnectivity calls back on
// a background queue.

/// The four activities, with `ActivityMode`'s raw values (that type lives in
/// the iPhone app). `WatchBridge.mode(for:)` maps between them.
nonisolated enum WatchActivity: String, Codable, CaseIterable, Sendable {
    case walking, running, cycling, stationary

    /// Lowercase noun: "walk", "run", "ride", "indoor walk".
    var noun: String {
        switch self {
        case .walking:    return "walk"
        case .running:    return "run"
        case .cycling:    return "ride"
        case .stationary: return "indoor walk"
        }
    }

    /// Sentence-case noun for a title: "Walk", "Indoor walk".
    var title: String { noun.prefix(1).uppercased() + noun.dropFirst() }

    /// The picker row's short name.
    var displayName: String {
        switch self {
        case .walking:    return "Walk"
        case .running:    return "Run"
        case .cycling:    return "Ride"
        case .stationary: return "Indoor"
        }
    }

    /// A ride shows speed; a walk or run shows pace; indoor shows neither.
    var showsSpeed: Bool { self == .cycling }
    var showsPace: Bool { self == .walking || self == .running }
}

/// What the watch asks the phone to do. Sent with `sendMessage` and a reply
/// handler only: a command is never queued for later delivery.
nonisolated enum WatchCommand: Codable, Equatable, Sendable {
    case start(WatchActivity)
    case pause
    case resume
    case finish
    case requestState
}

nonisolated enum WatchWalkPhase: String, Codable, CaseIterable, Sendable {
    case idle, running, paused, ended
}

/// What the phone saved, for the watch's summary.
nonisolated struct WatchWalkSummary: Codable, Equatable, Sendable {
    var distanceMeters: Double
    /// Time moving: the walk's elapsed time without its pauses.
    var movingSeconds: TimeInterval
}

/// The phone's walk as the watch shows it.
nonisolated struct WatchWalkState: Codable, Equatable, Sendable {
    var mode: WatchActivity
    var phase: WatchWalkPhase
    /// When the session began; nil while idle.
    var startDate: Date?
    /// Time paused so far, a pause in progress included (as the Live
    /// Activity sends it), so the watch's timer is
    /// `startDate + pausedDuration ... pauseTime: pausedAt`.
    var pausedDuration: TimeInterval = 0
    /// When this state was made, while paused: the timer's frozen end.
    var pausedAt: Date?
    /// Nil when the phone has no distance (an indoor walk before steps).
    var distanceMeters: Double?
    var currentPaceSecsPerKm: Double?
    var averagePaceSecsPerKm: Double?
    /// A ride's average speed, metres per second.
    var averageSpeedMetersPerSecond: Double?
    /// The person's unit: miles in the US, kilometres elsewhere.
    var usesMiles: Bool
    /// Whether the watch may pause and finish this session. False for an
    /// indoor walk, which has no pause and finishes on the phone.
    var controllable: Bool = true
    /// Set when `phase` is `.ended`.
    var summary: WatchWalkSummary?

    static func idle(usesMiles: Bool) -> WatchWalkState {
        WatchWalkState(mode: .walking, phase: .idle, usesMiles: usesMiles)
    }

    var isLive: Bool { phase == .running || phase == .paused }

    /// The start the elapsed-time text counts from: pauses moved out of it.
    var timerStart: Date? { startDate.map { $0.addingTimeInterval(pausedDuration) } }
}

/// The phone's answer to a command.
nonisolated enum WatchReply: Codable, Equatable, Sendable {
    /// The state after acting (or the current one for `requestState`).
    case state(WatchWalkState)
    /// The phone cannot start a session that tracks from here (it is not in
    /// front, or location is off): "Open Wockett on your iPhone to start."
    case needsPhone
    /// Pause, resume or finish with nothing running.
    case noActiveSession
}

// MARK: - Wire format

/// WatchConnectivity carries property-list dictionaries. Each message is one
/// JSON blob under one key, so the Codable types above are the only schema.
nonisolated enum WatchWire {
    static let key = "wockett.watch.v1"

    static func encode<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value) else { return [:] }
        return [key: data]
    }

    static func decode<T: Decodable>(_ type: T.Type, from message: [String: Any]) -> T? {
        guard let data = message[key] as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - How often the phone sends

/// The phone sends its state on every phase change, and at most every
/// `minimumInterval` while only the distance changes, so a long walk does
/// not flood the link. Pure, for the tests.
nonisolated struct WatchSendThrottle: Equatable {
    static let minimumInterval: TimeInterval = 5

    enum Decision: Equatable {
        case sendNow
        /// Distance moved inside the interval: send at this time.
        case sendAt(Date)
        case skip
    }

    private(set) var lastSent: WatchWalkState?
    private(set) var lastSentAt: Date?

    func decide(_ state: WatchWalkState, now: Date) -> Decision {
        guard let last = lastSent, let at = lastSentAt else { return .sendNow }
        if last.phase != state.phase || last.mode != state.mode
            || last.controllable != state.controllable || last.usesMiles != state.usesMiles
            || last.startDate != state.startDate {
            return .sendNow
        }
        guard Self.metres(last.distanceMeters) != Self.metres(state.distanceMeters) else { return .skip }
        let due = at.addingTimeInterval(Self.minimumInterval)
        return now >= due ? .sendNow : .sendAt(due)
    }

    mutating func didSend(_ state: WatchWalkState, at now: Date) {
        lastSent = state
        lastSentAt = now
    }

    /// Whole metres: GPS noise below a metre is not a change worth sending.
    private static func metres(_ value: Double?) -> Int? { value.map { Int($0.rounded(.down)) } }
}

// MARK: - What the watch shows

nonisolated enum WatchWalkFormat {
    static let metresPerMile = 1609.344

    /// "1.25 mi" or "2.01 km".
    static func distance(_ meters: Double, usesMiles: Bool) -> String {
        let value = max(0, meters) / (usesMiles ? metresPerMile : 1000)
        return String(format: "%.2f %@", value, usesMiles ? "mi" : "km")
    }

    /// "9:12 /mi" or "5:43 /km"; "--:--" without one.
    static func pace(secsPerKm: Double?, usesMiles: Bool) -> String {
        guard let secsPerKm, secsPerKm.isFinite, secsPerKm > 0 else { return "--:--" }
        let total = Int((usesMiles ? secsPerKm * metresPerMile / 1000 : secsPerKm).rounded())
        return String(format: "%d:%02d /%@", total / 60, total % 60, usesMiles ? "mi" : "km")
    }

    /// "12.4 mph" or "19.9 km/h"; "--" without one.
    static func speed(metersPerSecond: Double?, usesMiles: Bool) -> String {
        guard let mps = metersPerSecond, mps.isFinite, mps > 0 else { return "--" }
        let perHour = mps * 3600 / (usesMiles ? metresPerMile : 1000)
        return String(format: "%.1f %@", perHour, usesMiles ? "mph" : "km/h")
    }

    /// "42:07" or "1:02:07".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Wrist taps

/// A tap on the wrist while the watch app is open.
nonisolated enum WatchHapticEvent: Equatable, Sendable {
    case paused, resumed, finished
    /// The walk passed a whole mile or kilometre (the count passed).
    case marker(Int)
}

nonisolated enum WatchHaptics {
    /// What changed between the state the watch had and the one it got.
    /// Nothing for a first state (opening the app mid-walk taps nothing).
    static func events(from old: WatchWalkState?, to new: WatchWalkState) -> [WatchHapticEvent] {
        guard let old else { return [] }
        var events: [WatchHapticEvent] = []
        switch (old.phase, new.phase) {
        case (.running, .paused): events.append(.paused)
        case (.paused, .running): events.append(.resumed)
        case (.running, .ended), (.paused, .ended): events.append(.finished)
        default: break
        }
        // Markers only within one session, never from an old walk's distance.
        if old.isLive, new.isLive, old.startDate == new.startDate,
           let before = old.distanceMeters, let after = new.distanceMeters {
            let unit = new.usesMiles ? WatchWalkFormat.metresPerMile : 1000
            let passed = Int(after / unit)
            if passed > Int(before / unit), passed > 0 { events.append(.marker(passed)) }
        }
        return events
    }
}

// MARK: - The watch's screen

/// What the watch shows, worked out from what the phone has sent and what
/// the watch is waiting for. `WatchSessionModel` holds one and the views
/// draw it; the rules are here so the app's tests cover them.
nonisolated struct WatchRemoteDisplay: Equatable, Sendable {
    enum Screen: Equatable, Sendable { case idle, starting, live, summary }

    /// The latest state from the phone (application context or a reply).
    private(set) var state: WatchWalkState?
    /// Start was sent and the phone has not shown a running session yet.
    private(set) var isStarting = false
    /// The ended walk the summary shows until Done.
    private(set) var summary: WatchWalkState?
    /// The phone could not start: "Open Wockett on your iPhone to start."
    private(set) var needsPhone = false

    var screen: Screen {
        if summary != nil { return .summary }
        if state?.isLive == true { return .live }
        return isStarting ? .starting : .idle
    }

    /// A new state from the phone. Returns the wrist taps it calls for.
    mutating func receive(_ new: WatchWalkState) -> [WatchHapticEvent] {
        let taps = WatchHaptics.events(from: state, to: new)
        // An ended walk is shown only if this watch saw it running: an old
        // application context read at launch is not a walk just finished.
        if new.phase == .ended, new.summary != nil, state?.isLive == true {
            summary = new
        }
        if new.isLive {
            isStarting = false
            needsPhone = false
            summary = nil
        }
        state = new
        return taps
    }

    /// Start was pressed.
    mutating func beginStart() {
        isStarting = true
        needsPhone = false
        summary = nil
    }

    /// The phone's answer to a command. Returns the wrist taps it calls for.
    mutating func receive(reply: WatchReply, to command: WatchCommand) -> [WatchHapticEvent] {
        switch reply {
        case .state(let new):
            // Finish's own reply shows the summary even if the watch never
            // got the running state (it opened after the last update).
            if command == .finish, new.phase == .ended, new.summary != nil {
                let taps = state?.isLive == true ? receive(new) : [.finished]
                summary = new
                return taps
            }
            return receive(new)
        case .needsPhone:
            if case .start = command {
                isStarting = false
                needsPhone = true
            }
            return []
        case .noActiveSession:
            isStarting = false
            if let state { _ = receive(.idle(usesMiles: state.usesMiles)) }
            return []
        }
    }

    /// The command did not reach the phone, or Start waited too long.
    mutating func commandFailed() {
        isStarting = false
    }

    /// Done on the summary.
    mutating func dismissSummary() {
        summary = nil
    }

    /// The last state is kept while the phone is out of reach; only the
    /// buttons change (disabled), and a mark says so.
    static func controlsEnabled(state: WatchWalkState?, isReachable: Bool) -> Bool {
        isReachable && (state?.controllable ?? true)
    }
}
