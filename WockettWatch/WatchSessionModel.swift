import Foundation
import Observation
import WatchConnectivity
import WatchKit

/// Owns the Watch's `WCSession`. Holds the latest walk state from the phone
/// (its application context, or a reply) in a `WatchRemoteDisplay`, whose
/// rules live in WatchWalkLink.swift where the app's tests cover them, and
/// sends the person's commands. The watch tracks nothing itself: the phone
/// owns every session.
@Observable @MainActor
final class WatchSessionModel: NSObject {
    private(set) var display = WatchRemoteDisplay()
    private(set) var isReachable = false
    /// A command is on its way; the buttons wait for its reply.
    private(set) var isSending = false
    var selectedActivity: WatchActivity = .walking

    /// How long Start waits for the phone to show a running session.
    private static let startTimeout: Duration = .seconds(12)
    @ObservationIgnored private var startTimeoutTask: Task<Void, Never>?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #if DEBUG
        listenForDebugCommands()
        #endif
    }

    /// Ask the phone for its state; called when the app becomes active.
    func requestState() {
        let session = WCSession.default
        if !session.isReachable { markUnreachable() }
        if let context = WatchWire.decode(WatchWalkState.self, from: session.receivedApplicationContext) {
            apply(display.receive(context))
        }
        send(.requestState)
    }

    var controlsEnabled: Bool {
        WatchRemoteDisplay.controlsEnabled(state: display.state, isReachable: isReachable) && !isSending
    }

    func start() {
        display.beginStart()
        send(.start(selectedActivity))
        startTimeoutTask?.cancel()
        startTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.startTimeout)
            guard !Task.isCancelled, let self, self.display.screen == .starting else { return }
            self.display.commandFailed()
        }
    }

    func togglePause() {
        send(display.state?.phase == .paused ? .resume : .pause)
    }

    func finish() {
        send(.finish)
    }

    func dismissSummary() {
        display.dismissSummary()
    }

    // MARK: - Sending

    /// How long a command waits for the phone's reply before the watch says
    /// the iPhone is out of reach. Longer than the phone's 5 s wait for a
    /// walk to start.
    private static let replyTimeout: Duration = .seconds(10)
    /// How often the watch asks for the phone's state while it is marked
    /// out of reach (a request for state changes nothing on the phone).
    private static let recoveryInterval: Duration = .seconds(10)
    @ObservationIgnored private var pendingCommand: UUID?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?

    /// `sendMessage` with a reply, or nothing: a command the phone cannot
    /// get now is dropped, never queued to run later.
    private func send(_ command: WatchCommand) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            markUnreachable()
            if command != .requestState { display.commandFailed() }
            return
        }
        let id = UUID()
        if command != .requestState {
            isSending = true
            pendingCommand = id
            // A phone that went away without the system noticing yet: stop
            // waiting, say so, and let the person try again later.
            Task { [weak self] in
                try? await Task.sleep(for: Self.replyTimeout)
                guard let self, self.pendingCommand == id else { return }
                self.pendingCommand = nil
                self.isSending = false
                self.display.commandFailed()
                self.markUnreachable()
            }
        }
        session.sendMessage(WatchWire.encode(command), replyHandler: { message in
            let reply = WatchWire.decode(WatchReply.self, from: message)
            Task { @MainActor in self.received(reply, to: command, id: id) }
        }, errorHandler: { _ in
            Task { @MainActor in self.received(nil, to: command, id: id) }
        })
    }

    private func received(_ reply: WatchReply?, to command: WatchCommand, id: UUID) {
        if command != .requestState {
            // A reply after the timeout still shows the phone's state.
            if pendingCommand == id { pendingCommand = nil }
            isSending = pendingCommand != nil
        }
        guard let reply else {
            if !WCSession.default.isReachable { markUnreachable() }
            display.commandFailed()
            return
        }
        markReachable()
        apply(display.receive(reply: reply, to: command))
    }

    private func markReachable() {
        isReachable = true
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    /// Keeps the last state on screen, disables the buttons and asks for the
    /// state now and then until the phone answers (on a watch the system
    /// also reports the link coming back: `sessionReachabilityDidChange`).
    private func markUnreachable() {
        isReachable = false
        guard recoveryTask == nil else { return }
        recoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.recoveryInterval)
                guard let self, !self.isReachable else { return }
                if WCSession.default.isReachable { self.send(.requestState) }
            }
        }
    }

    // MARK: - Wrist taps

    private func apply(_ taps: [WatchHapticEvent]) {
        guard let tap = taps.last else { return }
        let device = WKInterfaceDevice.current()
        switch tap {
        case .paused:   device.play(.stop)
        case .resumed:  device.play(.start)
        case .finished: device.play(.success)
        case .marker:   device.play(.notification)
        }
    }

    #if DEBUG
    /// Debug builds press a button when a Darwin notification
    /// `wkt.watch.<start-walking|start-running|start-cycling|start-stationary|
    /// pause|resume|finish|done>` arrives, so paired simulators can be driven from
    /// the command line (`xcrun simctl spawn <watch> notifyutil -p
    /// wkt.watch.pause`); the watch simulator takes no scripted taps.
    /// Compiled out of release.
    static let debugCommands = ["start-walking", "start-running", "start-cycling", "start-stationary",
                                "pause", "resume", "finish", "done"]

    private func listenForDebugCommands() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        for word in Self.debugCommands {
            CFNotificationCenterAddObserver(center, observer, { _, observer, name, _, _ in
                guard let observer, let name = name?.rawValue as String? else { return }
                let model = Unmanaged<WatchSessionModel>.fromOpaque(observer).takeUnretainedValue()
                let word = String(name.dropFirst("wkt.watch.".count))
                Task { @MainActor in model.pressForDebugCommand(word) }
            }, "wkt.watch.\(word)" as CFString, nil, .deliverImmediately)
        }
    }

    private func pressForDebugCommand(_ word: String) {
        switch word {
        case "pause", "resume": togglePause()
        case "finish": finish()
        case "done": dismissSummary()
        default:
            guard word.hasPrefix("start-"),
                  let activity = WatchActivity(rawValue: String(word.dropFirst("start-".count))) else { return }
            selectedActivity = activity
            start()
        }
    }
    #endif

    fileprivate func contextArrived(_ state: WatchWalkState) {
        markReachable()
        apply(display.receive(state))
    }

    fileprivate func reachabilityChanged(_ reachable: Bool) {
        if reachable {
            if !isReachable { send(.requestState) }
        } else {
            markUnreachable()
        }
    }
}

extension WatchSessionModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.requestState()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let state = WatchWire.decode(WatchWalkState.self, from: applicationContext) else { return }
        Task { @MainActor in self.contextArrived(state) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachabilityChanged(reachable) }
    }
}
