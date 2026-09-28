import Foundation
import UserNotifications

@Observable @MainActor
final class ActiveWalkStore {
    static let shared = ActiveWalkStore()

    private(set) var session: NavigationSessionManager?
    private(set) var activeRoute: NavigableRoute?
    private(set) var isStarted: Bool = false
    private(set) var historyStore: WalkHistoryStore?

    /// `shared` is the app's store; tests build their own with an in-memory
    /// history store.
    init(historyStore: WalkHistoryStore? = nil) {
        self.historyStore = historyStore
    }

    func configure(historyStore: WalkHistoryStore) {
        self.historyStore = historyStore
    }

    /// Snapshots the current session into Walk History. Does NOT stop the session or
    /// clear the store — callers are responsible for that ordering. Safe to call with
    /// default args when per-pet distance data isn't available (e.g. from the mini tile).
    @discardableResult
    func buildAndSaveSession(
        petDistances: [UUID: Double] = [:],
        activePetIds: [UUID] = [],
        isCommunityRoute: Bool = false
    ) -> WalkSession? {
        guard let session, let historyStore else { return nil }
        var s = session.completedSession
        s.activePetIds = activePetIds
        s.petDistances = petDistances
        s.isCommunityRoute = isCommunityRoute
        historyStore.add(s)
        // Saved: the checkpoint has done its job. stop() deletes it too, but
        // the walk screen's completion path saves without stopping.
        ActiveWalkSnapshotStore.clear()
        BackgroundTaskManager.shared.scheduleCloudKitSync()
        return s
    }

    var isActive: Bool { session != nil }

    /// Saves the active walk and tears down the session in one call.
    /// For exit points that have no access to per-pet distance accrual
    /// (mini tile, Live Activity button) — the walk is saved but pets
    /// won't get distance credit for this session.
    @discardableResult
    func saveAndEndActiveSession() -> WalkSession? {
        guard let session, let route = activeRoute else { return nil }
        let dist           = session.totalDistanceCovered
        let elapsed        = Int(session.elapsedTime)
        let pausedDuration = session.totalPausedDuration
        let capturedSession = session
        let saved          = buildAndSaveSession(isCommunityRoute: route.isCommunityRoute)
        session.stop()
        endSession()
        NotificationService.shared.cancelWaterBreaks()
        Task {
            await WalkLiveActivityManager.shared.end(distanceCovered: dist, elapsedSeconds: elapsed, pausedDuration: pausedDuration)
            await capturedSession.finishWorkoutSession()
        }
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
    /// saves it (with per-pet distances) and shows the summary. Without it,
    /// minimised to the mini tile, nothing else would, so it is saved here
    /// the way the mini tile's own Save & End does, without pet credit.
    func sessionDidComplete() {
        guard let session, !session.isSessionScreenVisible else { return }
        saveAndEndActiveSession()
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
    }

    // MARK: - Reopen signal

    /// Set by the mini tile when the user taps "return to walk". Consumed by StepCounterView.
    private(set) var reopenRequested: Bool = false

    func requestReopen() { reopenRequested = true }
    func consumeReopenRequest() { reopenRequested = false }
}
