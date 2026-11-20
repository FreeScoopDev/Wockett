import Foundation
import UIKit
import CoreLocation
import WatchConnectivity
import Combine

// MARK: - WatchBridge (feat/watch-walk-remote)
//
// The iPhone side of the Apple Watch walk remote. The phone owns every
// session; the watch is a second screen and a remote. This class:
//
// - sends the walk's state (`WatchWalkState`, WatchWalkLink.swift) on every
//   phase change and at most every 5 s while only the distance moves;
// - acts on the watch's commands only through the paths the app already
//   has: Start posts to `WalkIntentInbox` like Siri and Control Center,
//   Pause and Resume do what the Live Activity's toggle does, and Finish is
//   `ActiveWalkStore.end(.save)` like the Live Activity's End;
// - starts only a session that can track. A When In Use app cannot start
//   location updates from the background, and a watch message wakes the
//   phone in the background (checked 2026-11-20):
//   https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background
//   https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:)
//   So Start works while Wockett is in front, and otherwise replies
//   `needsPhone`: nothing half-starts;
// - sends as soon as the walk changes, whichever path changed it (the Live
//   Activity's End, the mini tile, a salvage, the walk screen): it watches
//   `ActiveWalkStore` rather than waiting for the 1 s check, which iOS may
//   not run once the app is suspended.
//
// `WCSessionLink` below owns the `WCSession`; the bridge itself never touches
// WatchConnectivity, so a test drives it with a fake sink and its own store.

/// Where the bridge sends state. `WCSessionLink` in the app; a fake in tests.
@MainActor
protocol WatchStateSink: AnyObject {
    func send(_ state: WatchWalkState)
    /// Sends the glance in the application context (merged with the walk
    /// state) and/or as a complication transfer.
    func send(_ glance: WatchGlanceSnapshot, context: Bool, complication: Bool)
    /// Whether a glance can go now, and the complication budget.
    var glanceStatus: WatchGlanceLinkStatus { get }
}

extension WatchStateSink {
    /// A sink for the walk state only (the walk remote's tests) sends no glance.
    func send(_ glance: WatchGlanceSnapshot, context: Bool, complication: Bool) {}
    var glanceStatus: WatchGlanceLinkStatus { .unavailable }
}

/// Where the glance's numbers come from: the app's own stores, set at launch
/// (`SquatCounterApp`). Steps are what `WidgetSnapshot` wrote, the goal is
/// `StepManager`'s, and pets are `PetStore.todaySteps(for:in:)`, in the
/// pets list's order.
struct WatchGlanceSource {
    var steps: @MainActor () -> Int?
    var goal: @MainActor () -> Int
    var pets: @MainActor () -> [WatchGlancePet]
}

/// An indoor walk's numbers. Indoor walks run in `StationaryWalkView`, not
/// through `ActiveWalkStore`, so the screen reports them here. The watch
/// shows their time and distance; they have no pause and finish on the phone.
struct IndoorWalkReading: Equatable {
    var startDate: Date
    var distanceMeters: Double
}

@MainActor
final class WatchBridge {
    static let shared = WatchBridge(glancePolicyDefaults: .standard)

    private let store: ActiveWalkStore
    private let inbox: WalkIntentInbox
    /// Whether a session could track if started now: Wockett in front, and
    /// for an outdoor activity, location not off.
    private let canStart: @MainActor (WatchActivity) -> Bool
    private let isAppActive: @MainActor () -> Bool
    private let usesMiles: () -> Bool
    private let now: () -> Date
    /// How long Start waits for the walk screen to begin the session before
    /// replying. Zero in tests.
    private let startWait: TimeInterval

    weak var sink: (any WatchStateSink)?
    private(set) var throttle = WatchSendThrottle()
    private var link: WCSessionLink?
    private var timer: Timer?

    /// Set by the indoor walk screen while one runs. Each change is
    /// offered to the watch (throttled like the rest).
    var indoorWalk: IndoorWalkReading? {
        didSet { if observing { refresh() } }
    }
    /// Whether the bridge is watching the store (`observeStore`).
    private(set) var observing = false

    /// The glance's inputs; nil until the app sets them (and in tests that
    /// do not inject them), so nothing is sent.
    var glanceSource: WatchGlanceSource?
    private(set) var glancePolicy = WatchGlanceSendPolicy() {
        didSet { saveGlancePolicy() }
    }
    /// Where the policy is kept across launches; nil in tests.
    private let glancePolicyDefaults: UserDefaults?
    static let glancePolicyKey = "watch.glanceSendPolicy"
    private var glanceObservers: [AnyCancellable] = []

    init(store: ActiveWalkStore? = nil,
         inbox: WalkIntentInbox? = nil,
         canStart: (@MainActor (WatchActivity) -> Bool)? = nil,
         isAppActive: (@MainActor () -> Bool)? = nil,
         usesMiles: @escaping () -> Bool = { WalkAudioCueService.usesMiles },
         now: @escaping () -> Date = Date.init,
         startWait: TimeInterval = 5,
         glancePolicyDefaults: UserDefaults? = nil) {
        self.store = store ?? .shared
        self.inbox = inbox ?? .shared
        let isActive = isAppActive ?? { UIApplication.shared.applicationState == .active }
        self.isAppActive = isActive
        self.canStart = canStart ?? { mode in Self.canStartNow(mode, appIsActive: isActive()) }
        self.usesMiles = usesMiles
        self.now = now
        self.startWait = startWait
        self.glancePolicyDefaults = glancePolicyDefaults
        if let data = glancePolicyDefaults?.data(forKey: Self.glancePolicyKey),
           let saved = try? JSONDecoder().decode(WatchGlanceSendPolicy.self, from: data) {
            glancePolicy = saved
        }
    }

    private func saveGlancePolicy() {
        guard let glancePolicyDefaults, let data = try? JSONEncoder().encode(glancePolicy) else { return }
        glancePolicyDefaults.set(data, forKey: Self.glancePolicyKey)
    }

    // MARK: - Launch

    /// Called once at launch. Does nothing where WatchConnectivity is not
    /// supported (iPad) and under tests, which inject a sink instead.
    func activate() {
        guard link == nil, WCSession.isSupported(), !AppModelContainer.isRunningUnderTests else { return }
        let link = WCSessionLink(bridge: self)
        self.link = link
        sink = link
        link.activate()
        observeStore()
        #if DEBUG
        listenForDebugGlance()
        #endif
        // A local check once a second; what it sends is throttled.
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                WatchBridge.shared.refresh()
                WatchBridge.shared.refreshGlanceIfBehind()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Sends whenever anything `currentState()` reads changes, so a walk
    /// ended on any path reaches the watch at once. Each change re-arms the
    /// observation; what it sends is throttled. Called by `activate()`, and
    /// by tests with their own store.
    func observeStore() {
        observing = true
        withObservationTracking {
            _ = currentState()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observing else { return }
                self.refresh()
                self.observeStore()
            }
        }
    }

    // MARK: - State

    /// The walk as the watch should show it now.
    func currentState() -> WatchWalkState {
        let miles = usesMiles()
        if let session = store.session {
            let route = store.activeRoute ?? session.route
            let mode = Self.watchActivity(for: route.activityMode)
            let distance = session.totalDistanceCovered
            let elapsed = session.elapsedTime
            var state = WatchWalkState(mode: mode, phase: .running, usesMiles: miles)
            state.setWording(route.wording)
            state.startDate = session.startTime
            state.distanceMeters = distance
            guard store.isWalkInProgress else {
                state.phase = .ended
                state.summary = WatchWalkSummary(distanceMeters: distance, movingSeconds: elapsed)
                return state
            }
            state.phase = session.isPaused ? .paused : .running
            state.pausedDuration = session.totalPausedDuration
            state.pausedAt = session.isPaused ? now() : nil
            if mode.showsSpeed {
                // As the walk screen's ride speed: from 50 m and 5 s.
                state.averageSpeedMetersPerSecond = distance > 50 && elapsed > 5 ? distance / elapsed : nil
            } else {
                state.averagePaceSecsPerKm = session.averagePaceSecsPerKm
                state.currentPaceSecsPerKm = session.currentPaceSecsPerKm
            }
            return state
        }
        if let indoor = indoorWalk {
            var state = WatchWalkState(mode: .stationary, phase: .running, usesMiles: miles)
            state.setWording(SessionWording(.stationary))
            state.startDate = indoor.startDate
            state.distanceMeters = indoor.distanceMeters > 0 ? indoor.distanceMeters : nil
            state.controllable = false
            return state
        }
        return .idle(usesMiles: miles)
    }

    /// Sends the state if the throttle allows. The 1 s timer calls this, and
    /// every command does after acting.
    func refresh() {
        let state = currentState()
        let time = now()
        guard throttle.decide(state, now: time) == .sendNow else { return }
        sink?.send(state)
        throttle.didSend(state, at: time)
    }

    // MARK: - Glance (feat/watch-complications)

    /// The glance as the watch should have it now; nil without a source.
    func currentGlance() -> WatchGlanceSnapshot? {
        guard let glanceSource else { return nil }
        let time = now()
        return .make(steps: glanceSource.steps(), goal: glanceSource.goal(), pets: glanceSource.pets(),
                     dayStart: StepManager.trackingDayStart(now: time), now: time)
    }

    /// Sends the glance as `WatchGlanceSendPolicy` allows: the context on
    /// every change, a complication transfer within its budget and interval.
    /// Called when the step snapshot is written (foreground and background
    /// refresh), when pets, walks or the goal change, and on activation.
    func refreshGlance() {
        guard let sink, let glance = currentGlance() else { return }
        let time = now()
        let decision = glancePolicy.decide(glance, now: time, status: sink.glanceStatus)
        guard decision != .none else { return }
        sink.send(glance, context: decision.context, complication: decision.complication)
        glancePolicy.didSend(glance, decision, at: time)
    }

    /// The 1 s check: a complication transfer held back by the interval goes
    /// once the interval is up, without waiting for the next change.
    func refreshGlanceIfBehind() {
        if glancePolicy.complicationBehind { refreshGlance() }
    }

    /// The background refresh: the session may still be activating after a
    /// background launch, so wait for it (a few seconds at most) and send.
    func sendGlanceFromBackground(timeout: Duration = .seconds(3)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while sink?.glanceStatus.canSend != true, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        refreshGlance()
    }

    /// Re-sends the glance (debounced) whenever one of the app's stores
    /// changes: pets added, renamed or removed, a walk saved, the goal or
    /// the step count changed. Called once at launch with the app's stores.
    func observeGlanceInputs(_ publishers: [AnyPublisher<Void, Never>]) {
        guard !AppModelContainer.isRunningUnderTests else { return }
        glanceObservers = [
            Publishers.MergeMany(publishers)
                .debounce(for: .seconds(1), scheduler: RunLoop.main)
                .sink { _ in WatchBridge.shared.refreshGlance() }
        ]
    }

    /// The step count for the glance: what `WidgetSnapshot` last wrote, 0
    /// when that was before today's step day began, nil when nothing was
    /// ever written (no Health read yet).
    static func glanceSteps(_ values: WidgetSnapshot.Values?, dayStart: Date) -> Int? {
        guard let values else { return nil }
        guard let at = values.lastRefresh, at >= dayStart else { return 0 }
        return values.steps
    }

    /// The pets as the watch gets them: id, name, emoji, steps today and
    /// goal only (never the owner's contact details), in list order.
    static func glancePets(_ pets: [PetProfile], steps: (PetProfile) -> Int) -> [WatchGlancePet] {
        pets.map { pet in
            WatchGlancePet(id: pet.id, name: pet.name, emoji: pet.displayEmoji,
                           steps: steps(pet), goal: pet.goalSteps)
        }
    }

    #if DEBUG
    /// The simulators have no Health data, so Debug builds can push made-up
    /// numbers to the watch on a Darwin notification on the iPhone simulator:
    /// `xcrun simctl spawn <phone> notifyutil -p wkt.phone.glance.<word>`,
    /// where the word is `seed` (6,240 of 10,000 steps, two sample pets),
    /// `goal` (10,400 steps, goal reached), `nopets`, `more` (adds 500 steps)
    /// or `real` (back to the app's own numbers). Compiled out of release.
    static let debugGlanceWords = ["seed", "goal", "nopets", "more", "real"]
    private var realGlanceSource: WatchGlanceSource?
    private var debugSteps = 6_240

    private func listenForDebugGlance() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for word in Self.debugGlanceWords {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let name = name?.rawValue as String? else { return }
                let word = String(name.dropFirst("wkt.phone.glance.".count))
                Task { @MainActor in WatchBridge.shared.applyDebugGlance(word) }
            }, "wkt.phone.glance.\(word)" as CFString, nil, .deliverImmediately)
        }
    }

    private func applyDebugGlance(_ word: String) {
        if realGlanceSource == nil { realGlanceSource = glanceSource }
        let dog = WatchGlancePet(id: UUID(uuidString: "00000000-0000-0000-0000-00000000D0C0") ?? UUID(),
                                 name: "Sample dog", emoji: "🐕", steps: 4_100, goal: 8_000)
        let cat = WatchGlancePet(id: UUID(uuidString: "00000000-0000-0000-0000-00000000CA70") ?? UUID(),
                                 name: "Sample cat", emoji: "🐈", steps: 1_250, goal: 5_000)
        var pets = [cat, dog]
        switch word {
        case "real":
            glanceSource = realGlanceSource
            realGlanceSource = nil
            refreshGlance()
            return
        case "goal": debugSteps = 10_400
        case "more": debugSteps += 500
        case "nopets": pets = []
        default: debugSteps = 6_240
        }
        let steps = debugSteps
        glanceSource = WatchGlanceSource(steps: { steps }, goal: { 10_000 }, pets: { pets })
        refreshGlance()
    }
    #endif

    // MARK: - Commands

    func handle(_ command: WatchCommand) async -> WatchReply {
        defer { refresh() }
        switch command {
        case .requestState:
            return .state(currentState())

        case .start(let activity):
            // A session already running is shown, never replaced.
            if store.isWalkInProgress || indoorWalk != nil { return .state(currentState()) }
            guard canStart(activity) else { return .needsPhone }
            inbox.post(WalkIntentRequest(mode: Self.mode(for: activity)))
            await waitForStart()
            // Not begun in time (a question on the phone's screen, say): say
            // so rather than leave the watch on "Starting…". If it begins
            // later, the next state shows it.
            guard store.isWalkInProgress || indoorWalk != nil else { return .notStarted }
            return .state(currentState())

        case .pause, .resume:
            guard let session = store.session, store.isWalkInProgress else {
                return indoorWalk != nil ? .needsPhone : .noActiveSession
            }
            // As ToggleWalkPauseLiveActivityIntent, but never toggles the
            // wrong way: a Pause that arrives already paused does nothing.
            let wantsPause = command == .pause
            if wantsPause, !session.isPaused { session.pause(); session.pushLiveActivityState() }
            if !wantsPause, session.isPaused { session.resume(); session.pushLiveActivityState() }
            return .state(currentState())

        case .finish:
            guard store.isWalkInProgress else {
                return indoorWalk != nil ? .needsPhone : .noActiveSession
            }
            // As the Live Activity's End, plus the phone's own summary when
            // someone is looking at the phone (a guided walk completing while
            // minimised does the same).
            guard let saved = store.end(.save, presentSummary: isAppActive()) else {
                // The save failed: the walk is still on, paused, and the
                // phone is asking what to do.
                return .state(currentState())
            }
            var state = WatchWalkState(mode: Self.watchActivity(for: ActivityMode(rawValue: saved.activityType) ?? .walking),
                                       phase: .ended, usesMiles: usesMiles())
            state.setWording(saved.wording)
            state.startDate = saved.date
            state.distanceMeters = saved.totalDistance
            state.summary = WatchWalkSummary(distanceMeters: saved.totalDistance, movingSeconds: saved.elapsedTime)
            return .state(state)
        }
    }

    /// Start posts the request; the walk screen begins the session a moment
    /// later. Waits a little for that, so the reply carries the running walk.
    private func waitForStart() async {
        let deadline = now().addingTimeInterval(startWait)
        while now() < deadline, !store.isWalkInProgress, indoorWalk == nil {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: - Mapping

    static func mode(for activity: WatchActivity) -> ActivityMode {
        switch activity {
        case .walking:    return .walking
        case .running:    return .running
        case .cycling:    return .cycling
        case .stationary: return .stationary
        }
    }

    static func watchActivity(for mode: ActivityMode) -> WatchActivity {
        switch mode {
        case .walking:    return .walking
        case .running:    return .running
        case .cycling:    return .cycling
        case .stationary: return .stationary
        }
    }

    /// A session tracks only if it starts with Wockett in front (Apple's docs:
    /// no starting location from the background with When In Use). An
    /// outdoor activity also needs location not to be off; an indoor walk
    /// counts steps.
    static func canStartNow(_ activity: WatchActivity, appIsActive: Bool,
                            authorization: () -> CLAuthorizationStatus = { CLLocationManager().authorizationStatus }) -> Bool {
        guard appIsActive else { return false }
        guard activity != .stationary else { return true }
        switch authorization() {
        case .denied, .restricted: return false
        default: return true
        }
    }
}

// MARK: - WCSessionLink

/// Owns the iPhone's `WCSession`. Commands arrive with a reply handler and
/// are answered at once; nothing is queued (no `transferUserInfo`).
final class WCSessionLink: NSObject, WCSessionDelegate, WatchStateSink {
    private weak var bridge: WatchBridge?
    /// The walk state and the glance share the one application context;
    /// each send keeps the other's latest (`WatchApplicationContext`).
    /// Seeded from what the session last sent, so a relaunch keeps both.
    private var context: WatchApplicationContext?

    init(bridge: WatchBridge) {
        self.bridge = bridge
    }

    func activate() {
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func send(_ state: WatchWalkState) {
        // No isPaired / isWatchAppInstalled check: the call throws when
        // there is no watch app, and those flags lag (paired simulators
        // report the app uninstalled after it is merely relaunched).
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        var merged = context ?? WatchApplicationContext(session.applicationContext)
        merged.set(state)
        context = merged
        try? session.updateApplicationContext(merged.dictionary)
    }

    func send(_ glance: WatchGlanceSnapshot, context sendContext: Bool, complication: Bool) {
        let session = WCSession.default
        guard glanceStatus.canSend else { return }
        if sendContext {
            var merged = context ?? WatchApplicationContext(session.applicationContext)
            merged.set(glance)
            context = merged
            try? session.updateApplicationContext(merged.dictionary)
        }
        // Only with a complication on the face and budget left (the policy
        // checked); otherwise the system would send it as plain user info.
        if complication, session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0 {
            session.transferCurrentComplicationUserInfo(WatchGlanceWire.payload(glance))
        }
    }

    /// A glance goes only to an installed Watch app on a paired watch.
    var glanceStatus: WatchGlanceLinkStatus {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            return .unavailable
        }
        return WatchGlanceLinkStatus(canSend: true, complicationEnabled: session.isComplicationEnabled,
                                     remainingTransfers: session.remainingComplicationUserInfoTransfers)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.bridge?.refreshAfterActivation() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The person switched watches: activate again for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard let command = WatchWire.decode(WatchCommand.self, from: message) else {
            replyHandler([:])
            return
        }
        let reply = UncheckedReply(handler: replyHandler)
        Task { @MainActor in
            let answer = await self.bridge?.handle(command) ?? .noActiveSession
            var message = WatchWire.encode(answer)
            // Opening the Watch app asks for state; it gets the glance too.
            if command == .requestState, let glance = self.bridge?.currentGlance() {
                message.merge(WatchGlanceWire.payload(glance)) { _, new in new }
            }
            reply.handler(message)
        }
    }

    /// The reply handler crosses to the main actor and back; WatchConnectivity
    /// allows calling it from any thread.
    private struct UncheckedReply: @unchecked Sendable {
        let handler: ([String: Any]) -> Void
    }
}

extension WatchWalkState {
    /// The phone's own words for the session, so a hike says "hike".
    mutating func setWording(_ wording: SessionWording) {
        noun = wording.noun
        title = wording.displayName
    }
}

extension WatchBridge {
    /// A newly activated session sends the current state whatever was last
    /// sent before, so a watch paired mid-walk gets it.
    fileprivate func refreshAfterActivation() {
        throttle = WatchSendThrottle()
        refresh()
        glancePolicy.forgetContext()
        refreshGlance()
    }
}
