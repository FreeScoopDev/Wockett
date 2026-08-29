import Foundation

@Observable @MainActor
final class ActiveWalkStore {
    static let shared = ActiveWalkStore()

    private(set) var session: NavigationSessionManager?
    private(set) var activeRoute: NavigableRoute?
    private(set) var isStarted: Bool = false
    private(set) var historyStore: WalkHistoryStore?

    private init() {}

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
        BackgroundTaskManager.shared.scheduleCloudKitSync()
        return s
    }

    var isActive: Bool { session != nil }

    /// Creates a session for `route` and returns it. Returns nil without side effects if a session is already active.
    @discardableResult
    func beginSession(route: NavigableRoute) -> NavigationSessionManager? {
        guard session == nil else { return nil }
        let mgr = NavigationSessionManager(route: route)
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
