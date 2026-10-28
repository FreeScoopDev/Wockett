import SwiftUI
import SwiftData
import BackgroundTasks
import UserNotifications
import CoreLocation

// MARK: - UI Test Detection

#if DEBUG
let isWKTUITestMode = ProcessInfo.processInfo.arguments.contains("-WKTUITest")
/// `-WKTDemo`: seeded, in-memory demo state for the how-to videos (DemoMode).
let isWKTDemoMode = DemoMode.isRequested(by: ProcessInfo.processInfo.arguments)
#else
let isWKTUITestMode = false
let isWKTDemoMode = false
#endif

// MARK: - App Entry Point

@main
struct SquatCounterApp: App {
    private let container = AppModelContainer.shared
    @StateObject private var petStore:     PetStore
    @StateObject private var stepManager:  StepManager
    @StateObject private var routeManager: RouteManager
    @StateObject private var routeStore:   CustomRouteStore
    @StateObject private var historyStore: WalkHistoryStore
    @StateObject private var tabRouter:    TabRouter
    @State private var communityRoutesModel = CommunityRoutesModel()
    @State private var showSplash = !isWKTUITestMode
    /// The "Save walk" nudge's walk did not save (`saveUntrackedWalk`).
    @State private var untrackedSaveFailed = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundTaskManager.shared.registerTasks()
        UNUserNotificationCenter.current().delegate = AppNotificationDelegate.shared
        // Construct all shared stores before @StateObject wraps them — same pattern as PetStore.
        _petStore     = StateObject(wrappedValue: PetStore(context: AppModelContainer.shared.mainContext))
        let routeStore   = CustomRouteStore()
        let historyStore = WalkHistoryStore()
        #if DEBUG
        // -WKTDemo: seeded before the first frame, so a recording never shows
        // an empty screen filling in. The stores are on the in-memory demo
        // container (AppModelContainer.shared). A no-op without the flag.
        let arguments = ProcessInfo.processInfo.arguments
        DemoMode.seedIfRequested(arguments: arguments, history: historyStore, routes: routeStore)
        let fixedLocation = DemoMode.location(arguments: arguments)
        #else
        let fixedLocation: CLLocation? = nil
        #endif
        _stepManager  = StateObject(wrappedValue: StepManager())
        _routeManager = StateObject(wrappedValue: RouteManager(fixedLocation: fixedLocation))
        _routeStore   = StateObject(wrappedValue: routeStore)
        _historyStore = StateObject(wrappedValue: historyStore)
        _tabRouter    = StateObject(wrappedValue: TabRouter())
        // Tip jar. Starts the Transaction.updates listener and reconciles the
        // supporter ledger against StoreKit's history. Must run for the whole
        // process or a transaction completing outside a purchase call — Ask to
        // Buy approval, an interrupted purchase, a tip made on another device —
        // is never recorded. Skipped under test for the same reason CloudKit is:
        // test runs should not touch a real StoreKit session.
        // Trail region packs. The home region ships in the bundle so trails
        // work on a first launch with no network; opening is milliseconds.
        TrailPackLibrary.shared.loadBundled()
        if !AppModelContainer.isRunningUnderTests {
            TipJarStore.shared.start()
            // Pro entitlement. Reads StoreKit and the supporter ledger, records
            // the answer to the app group, and listens for changes. Feature-
            // flagged off, so it gates nothing yet — see ProGating.
            ProEntitlementStore.shared.start()
        }
        #if DEBUG
        if isWKTUITestMode { UIView.setAnimationsEnabled(false) }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                TabView(selection: $tabRouter.selected) {
                    Tab(value: AppTab.health) {
                        NavigationStack {
                            HealthHubView()
                        }
                    } label: {
                        Label { Text("Health") } icon: { Image(wkt: .health) }
                    }
                    .accessibilityIdentifier("tab.health")
                    Tab(value: AppTab.routes) {
                        NavigationStack {
                            RouteFinderContentView(
                                routeManager: routeManager,
                                historyStore: historyStore,
                                routeStore: routeStore,
                                stepManager: stepManager,
                                onNavigateAway: {
                                    ActiveWalkStore.shared.requestReopen()
                                    tabRouter.selected = .home
                                }
                            )
                        }
                    } label: {
                        Label { Text("Routes") } icon: { Image(wkt: .routes) }
                    }
                    .accessibilityIdentifier("tab.routes")
                    Tab("Home", image: "wkt.home.pin", value: AppTab.home) {
                        NavigationStack {
                            StepCounterView()
                        }
                    }
                    .accessibilityIdentifier("tab.home")
                    Tab(value: AppTab.community) {
                        NavigationStack {
                            CommunityHubView()
                        }
                    } label: {
                        Label { Text("Community") } icon: { Image(wkt: .community) }
                    }
                    .accessibilityIdentifier("tab.community")
                    Tab(value: AppTab.settings) {
                        NavigationStack {
                            SettingsView()
                        }
                    } label: {
                        Label { Text("Settings") } icon: { Image(wkt: .settings) }
                    }
                    .accessibilityIdentifier("tab.settings")
                }
                // Bottom tab bar on iPhone; top tab bar / sidebar on iPad.
                .tabViewStyle(.sidebarAdaptable)
                // Tab bar collapses on downward scroll (iPhone only; ignored on iPad).
                .tabBarMinimizeBehavior(.onScrollDown)
                // Caps system-styled text (`.font(.body)`, system controls) at
                // Accessibility 2. It cannot cap Wockett's own type scale, whose
                // point size is resolved before SwiftUI reads this; that clamps
                // itself to the same size in `Font.wktScaledSize` (DesignSystem.swift).
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                // Active walk tile; isEnabled:false completely hides the capsule when idle.
                .tabViewBottomAccessory(isEnabled: ActiveWalkStore.shared.isActive) {
                    ActiveMiniTileContainer()
                }
                .tint(.earthGreen)

                // Splash renders on top from the very first frame — no system presentation
                // delay, so the dashboard is never visible before it. showSplash starts true
                // on cold launch; @State persists across background/foreground, so the splash
                // never re-appears when the user returns to an already-open app.
                if showSplash {
                    SplashView { showSplash = false }
                        .ignoresSafeArea()
                        .zIndex(1)
                }
            }
            // A walk ended from outside the walk screen (the mini tile's
            // Save & End): the same summary the walk screen ends on.
            .fullScreenCover(item: Binding(
                get: { ActiveWalkStore.shared.pendingSummary },
                set: { ActiveWalkStore.shared.pendingSummary = $0 }
            )) { request in
                // As the walk screen does: splits, and Exclude for a saved route.
                ActivitySummaryView(
                    session: request.session,
                    records: request.records,
                    splits: request.splits,
                    onExcludeFromRouteStats: request.session.customRouteId != nil ? {
                        historyStore.updateCountsTowardRouteStats(id: request.session.id, counts: false)
                    } : nil,
                    trail: request.trail
                )
            }
            // The mini tile's End asks here, not in the tile (see the modifier).
            .modifier(MiniTileEndConfirmation())
            // A walk whose save failed away from the walk screen.
            .modifier(WalkSaveFailureAlert())
            // The "Save walk" nudge's walk, when its save failed.
            .saveFailureAlert(noun: untrackedSaveFailed ? ActivityMode.walking.noun : nil,
                              onTryAgain: { untrackedSaveFailed = false; saveUntrackedWalk() },
                              onKeepGoing: { untrackedSaveFailed = false })
            .environment(ActiveWalkStore.shared)
            .environment(communityRoutesModel)
            .environmentObject(petStore)
            .environmentObject(stepManager)
            .environmentObject(routeManager)
            .environmentObject(routeStore)
            .environmentObject(historyStore)
            .environmentObject(tabRouter)
            .onChange(of: NotificationService.shared.pendingAction) { _, _ in
                handleNotificationAction()
            }
            // Siri's intent runs in this process while the app is up.
            .onChange(of: WalkIntentInbox.shared.pending) { _, _ in
                handleWalkIntent()
            }
            // A challenge link (https://wockett.app/c/?id=…). iOS delivers a
            // universal link as a browsing activity; onOpenURL covers the rest.
            .onOpenURL { url in ChallengeLinkInbox.shared.post(url) }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { ChallengeLinkInbox.shared.post(url) }
            }
            .onChange(of: ChallengeLinkInbox.shared.pending) { _, _ in
                handleChallengeLink()
            }
            // After a personal record or a new badge, once per version.
            .asksForReviewWhenDue()
            // The Control Center button runs in the widget process and can only
            // leave its request in the app group; read it every time the app
            // comes to the front, since a running app gets no launch.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { handleWalkIntent() }
            }
            .modelContainer(container)
            .task {
                // Boot ordering: configure + salvage run synchronously (no suspension)
                // before the Live Activity reap, so the reap and Home's
                // hasRestorableWalk check both see consistent session state.
                ActiveWalkStore.shared.configure(historyStore: historyStore)
                // Not in demo mode: salvaging a real walk's checkpoint would save
                // it into the throwaway demo store and delete the checkpoint.
                if !isWKTDemoMode { ActiveWalkStore.shared.salvageStaleWalkIfNeeded() }
                if ActiveWalkStore.shared.session == nil {
                    await WalkLiveActivityManager.shared.endAllActivities()
                }
                #if DEBUG
                // -WKTDemo: a clean start for a recording. The seed went in at
                // init; every step below can raise a permission sheet or a banner
                // (notification authorisation, Health) or touch the user's iCloud.
                if isWKTDemoMode { return }
                if isWKTUITestMode {
                    DevSeedStore.seedScreenshotDemo(history: historyStore, pets: petStore, routes: routeStore)
                    return
                }
                #endif
                // Before anything else: a notification tapped while the app was not
                // running sets this from the delegate, which can happen before this
                // view exists — `onChange` would never see it.
                handleNotificationAction()
                // A "Save walk" whose save failed last time is still pending.
                if !untrackedSaveFailed, NotificationService.shared.pendingUntrackedWalk != nil {
                    saveUntrackedWalk()
                }
                handleWalkIntent()
                handleChallengeLink()
                ActivityDetectionService.shared.startDetectionIfAuthorized()
                // Blocks live in your private iCloud too: bring in ones made on
                // another device or before a reinstall, and sync every change.
                // Not in the unit-test host: tests sync against a fake backend.
                if !AppModelContainer.isRunningUnderTests {
                    BlockListSync.shared.start()
                    BlockListSync.shared.sync()
                }
                // Shows no UI. Done at launch so the Health tab already knows
                // whether to show its cards or the connect card.
                Task { await HealthExtrasAccess.shared.refresh() }
                NotificationService.shared.registerCategories()
                NotificationService.shared.pruneExpiredWalkReminders()
                // Quiet delivery, once, only if never asked. The real prompt is Settings' job.
                await NotificationService.shared.requestQuietDeliveryIfNeverAsked()
                await scheduleWeeklySummaryNotification()
            }
        }
    }

    /// Acts on whatever a notification tap left pending. Called from `.task` at
    /// launch as well as `onChange`, because a tap that launches the app runs the
    /// delegate before this view exists and `onChange` only sees later changes.
    @MainActor
    private func handleNotificationAction() {
        let service = NotificationService.shared
        guard let action = service.consumePendingAction() else { return }
        switch action {
        case NotificationAction.startWalk:
            // Land on Home, and if a session is already running, reopen it
            // instead of starting over.
            tabRouter.selected = .home
            if ActiveWalkStore.shared.isActive { ActiveWalkStore.shared.requestReopen() }
        case NotificationAction.saveWalk:
            // Save the walk the nudge described and show it, so the user can see
            // it landed — and rename or retype it from history if they want.
            saveUntrackedWalk()
        default:
            break
        }
    }

    /// Saves the walk the "Save walk" nudge described and shows it in Activity
    /// History. Only a walk that is on disk is shown as landed: a failed save
    /// keeps the walk pending and asks (`untrackedSaveFailed`); Keep going
    /// leaves it for the next launch, which tries again.
    @MainActor
    private func saveUntrackedWalk() {
        switch NotificationService.shared.savePendingUntrackedWalk({ historyStore.add($0.toWalkSession()) }) {
        case true?:  tabRouter.selected = .health
        case false?: untrackedSaveFailed = true
        case nil:    break
        }
    }

    /// Acts on a walk Siri or the Control Center button asked for. Home opens
    /// the walk screen; a walk already in progress is brought back instead of
    /// being replaced.
    @MainActor
    private func handleWalkIntent() {
        guard let request = WalkIntentInbox.shared.consume() else { return }
        tabRouter.selected = .home
        if ActiveWalkStore.shared.isActive {
            ActiveWalkStore.shared.requestReopen()
        } else {
            tabRouter.pendingWalkStart = request.mode
        }
    }

    /// Opens the challenge a link named: Community → Challenges → that one.
    @MainActor
    private func handleChallengeLink() {
        guard let recordName = ChallengeLinkInbox.shared.consume() else { return }
        tabRouter.selected = .community
        tabRouter.pendingCommunityDestination = .challenge(recordName: recordName)
    }

    // Moved from StepCounterView so it runs once at launch, not on every Home tab appear.
    @MainActor
    private func scheduleWeeklySummaryNotification() async {
        let sessions = historyStore.sessions
        let streak   = StreakStore.shared.currentStreak

        let weekSessions = Self.weeklySummarySessions(sessions, now: Date(), calendar: .current)
        let week       = Self.weeklySummaryTotals(weekSessions)
        let body       = Self.weeklySummaryBody(steps: week.steps, km: week.km, streak: streak)

        var comps      = DateComponents()
        comps.weekday  = 1; comps.hour = 20; comps.minute = 0
        let trigger    = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        await NotificationService.shared.schedule(.weeklySummary, title: "Your week in review 📊", body: body, trigger: trigger)
    }

    /// The calendar week so far, the same week Insights calls "This week".
    nonisolated static func weeklySummarySessions(_ sessions: [WalkSession], now: Date,
                                                  calendar: Calendar) -> [WalkSession] {
        let window = InsightsSummary.calendarWeek(containing: now, calendar: calendar)
        return sessions.filter { InsightsSummary.counts($0.date, in: window, now: now) }
    }

    /// The weekly summary's figures for the sessions already in the week.
    /// Steps leave rides out (`humanSteps`); distance keeps every activity.
    nonisolated static func weeklySummaryTotals(_ weekSessions: [WalkSession]) -> (steps: Int, km: Double) {
        (weekSessions.reduce(0) { $0 + ActivitySummaryContent.humanSteps($1) },
         weekSessions.reduce(0.0) { $0 + $1.totalDistance } / 1000)
    }

    /// The weekly summary's text. A week of rides only has no steps (rides
    /// add none) but did happen, so it gets its distance rather than "a new
    /// week starts today"; that line is only for a week with nothing in it.
    nonisolated static func weeklySummaryBody(steps: Int, km: Double, streak: Int) -> String {
        let streakSuffix = streak > 0 ? " · \(streak)-day streak 🔥" : ""
        let kmText = String(format: "%.1f", km)
        if steps > 0 {
            return "This week: \(steps.formatted()) steps · \(kmText) km\(streakSuffix). Keep it up!"
        } else if km > 0 {
            return "This week: \(kmText) km\(streakSuffix). Keep it up!"
        } else {
            return "A new week starts today — lace up and start strong! 💪"
        }
    }
}


