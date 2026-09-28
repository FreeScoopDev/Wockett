import Foundation
import UserNotifications

@Observable @MainActor
final class ActiveWalkStore {
    static let shared = ActiveWalkStore()

    private(set) var session: NavigationSessionManager?
    private(set) var activeRoute: NavigableRoute?
    private(set) var isStarted: Bool = false
    private(set) var historyStore: WalkHistoryStore?
    private let notifications: NotificationService
    /// Set by `end`: a walk ends once, however many paths try. Cleared when
    /// the session is released.
    @ObservationIgnored private var sessionEnded = false

    /// `shared` is the app's store; tests build their own with an in-memory
    /// history store.
    init(historyStore: WalkHistoryStore? = nil, notifications: NotificationService? = nil) {
        self.historyStore = historyStore
        self.notifications = notifications ?? .shared
    }

    func configure(historyStore: WalkHistoryStore) {
        self.historyStore = historyStore
    }

    var isActive: Bool { session != nil }

    // MARK: - Ending a walk

    enum EndOutcome { case save, discard }

    /// The one way a walk ends, whoever ends it: the walk screen's Finish and
    /// Discard, the break prompt, the driving banner, route completion, the
    /// mini tile and the Live Activity. Until 2026-09-28 seven places
    /// re-implemented this, and each left something out: free walks never
    /// finished their Health workout, the mini tile and Live Activity saved no
    /// pet credit, the driving banner ended the Live Activity twice.
    ///
    /// Save: the walk goes to Walk History with every pet's credit and its
    /// Health workout is finished. Discard: the Health workout is thrown away.
    /// Either way tracking stops, the checkpoint is deleted, water-break
    /// reminders are cancelled and the Live Activity ends.
    ///
    /// `releaseSession: false` keeps the stopped session for the walk
    /// screen's summary; the screen calls `endSession()` when it goes away.
    /// Returns the saved walk; nil for a discard or a walk already ended.
    @discardableResult
    func end(_ outcome: EndOutcome, releaseSession: Bool = true) -> WalkSession? {
        guard let session, let route = activeRoute, !sessionEnded else { return nil }
        sessionEnded = true
        let distance = session.totalDistanceCovered
        let elapsed  = Int(session.elapsedTime)
        let paused   = session.totalPausedDuration
        var saved: WalkSession?
        switch outcome {
        case .save:
            if let historyStore {
                var walk = session.completedSession
                let pets = session.petDistances
                walk.activePetIds = Array(pets.keys)
                walk.petDistances = pets
                walk.isCommunityRoute = route.isCommunityRoute
                historyStore.add(walk)
                BackgroundTaskManager.shared.scheduleCloudKitSync()
                saved = walk
            }
        case .discard:
            session.discardWorkoutSession()
        }
        session.stop()
        notifications.cancelWaterBreaks()
        Task {
            await WalkLiveActivityManager.shared.end(distanceCovered: distance, elapsedSeconds: elapsed, pausedDuration: paused)
            if outcome == .save { await session.finishWorkoutSession() }
        }
        if releaseSession { endSession() }
        return saved
    }

    /// Reconstructs the last checkpointed walk if one exists and nothing is
    /// currently active. Returns the restored route on success.
    @discardableResult
    func restoreIfNeeded() -> NavigableRoute? {
        guard session == nil, let snapshot = ActiveWalkSnapshotStore.load() else { return nil }
        let route = snapshot.route.navigableRoute
        let mgr = NavigationSessionManager(route: route)
        mgr.onRouteChanged = { [weak self] in self?.activeRoute = $0 }
        mgr.onCompleted = { [weak self] in self?.sessionDidComplete() }
        mgr.restore(from: snapshot)
        session = mgr
        activeRoute = route
        isStarted = true
        // Start a fresh Live Activity for the restored session and push an immediate
        // state update so the banner shows current distance/elapsed rather than zeros.
        let capturedMgr = mgr
        Task {
            await WalkLiveActivityManager.shared.start(
                routeName: route.name,
                totalDistanceMeters: capturedMgr.liveActivityTotalMeters,
                activityMode: route.activityMode.rawValue,
                startDate: snapshot.startTime
            )
            await WalkLiveActivityManager.shared.update(
                distanceCovered: capturedMgr.totalDistanceCovered,
                elapsedSeconds: Int(capturedMgr.elapsedTime),
                isPaused: capturedMgr.isPaused,
                paceSecsPerKm: nil,
                pausedDuration: capturedMgr.totalPausedDuration,
                pauseTime: capturedMgr.isPaused ? Date() : nil
            )
        }
        return route
    }

    /// If a checkpoint exists but is too old to offer for resume, convert it
    /// into a Walk History entry and clear the checkpoint. Silent — no PR
    /// fanfare, no completion UI. Must be called after configure(historyStore:).
    func salvageStaleWalkIfNeeded() {
        guard session == nil,
              let historyStore,
              let snapshot = ActiveWalkSnapshotStore.loadAnyAge()
        else { return }
        // A finished guided walk the app died before saving is saved now,
        // whatever its age or length: the person reached the end.
        let completed = snapshot.isCompleted == true
        guard completed || Date().timeIntervalSince(snapshot.checkpointDate) > ActiveWalkSnapshotStore.maxSnapshotAge
        else { return }
        defer { ActiveWalkSnapshotStore.clear() }

        // Ignore trivial walks — same 50m threshold used by the Free Walk summary auto-save.
        guard completed || snapshot.totalDistanceCovered >= 50 else { return }

        let path = Self.salvagedWaypoints(for: snapshot)

        let salvaged = WalkSession(
            id: UUID(),
            routeName: snapshot.route.name,
            date: snapshot.startTime,
            elapsedTime: ActiveWalkSnapshotStore.salvagedElapsed(for: snapshot),
            totalDistance: snapshot.totalDistanceCovered,
            waypoints: path,
            lapCount: snapshot.route.lapCount,
            isLoop: snapshot.route.isLoop,
            activityType: snapshot.route.activityMode,
            steps: snapshot.liveSteps,
            customRouteId: snapshot.route.customRouteId
        )
        historyStore.add(salvaged)
    }

    /// The points a salvaged walk keeps: the breadcrumbs of a free walk, and
    /// for a guided one what Walk History keeps for its route.
    static func salvagedWaypoints(for snapshot: ActiveWalkSnapshot) -> [WaypointCoord] {
        let route = snapshot.route.navigableRoute
        return route.waypoints.isEmpty
            ? (snapshot.trackPoints ?? [])
            : route.historyWaypoints.map { WaypointCoord($0) }
    }

    /// A guided walk reached its end. With the walk screen up, the screen
    /// ends it and shows the summary. Without it, minimised to the mini tile,
    /// nothing else would, so it ends here, pet credit included.
    func sessionDidComplete() {
        guard let session, !session.isSessionScreenVisible else { return }
        end(.save)
    }

    /// Called when the user declines to resume a recovered walk.
    func declineRestore() {
        ActiveWalkSnapshotStore.clear()
    }

    var hasRestorableWalk: Bool {
        session == nil && ActiveWalkSnapshotStore.hasPending
    }

    /// Creates a session for `route` and returns it. Returns nil without side effects if a session is already active.
    /// Every guided walk starts here, so this is where a recorded walk saved as
    /// a route becomes a line to follow rather than hundreds of MKDirections legs.
    @discardableResult
    func beginSession(route: NavigableRoute) -> NavigationSessionManager? {
        guard session == nil else { return nil }
        let route = route.followingRecordedLine()
        let mgr = NavigationSessionManager(route: route)
        mgr.onRouteChanged = { [weak self] in self?.activeRoute = $0 }
        mgr.onCompleted = { [weak self] in self?.sessionDidComplete() }
        session = mgr
        activeRoute = route
        isStarted = false
        return mgr
    }

    func markStarted() {
        isStarted = true
    }

    func endSession() {
        session = nil
        activeRoute = nil
        isStarted = false
        sessionEnded = false
    }

    // MARK: - Reopen signal

    /// Set by the mini tile when the user taps "return to walk". Consumed by StepCounterView.
    private(set) var reopenRequested: Bool = false

    func requestReopen() { reopenRequested = true }
    func consumeReopenRequest() { reopenRequested = false }
}
