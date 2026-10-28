import SwiftUI
import MapKit
import CoreLocation
import UserNotifications
import UIKit
import MessageUI

// MARK: - Active Session View
//
// Unified active-session screen for guided routes (waypoints ≠ empty) and
// free sessions (waypoints empty).  Replaces WalkNavigationView + FreeWalkView.

struct ActiveSessionView: View {
    /// Used only when creating a free-session stub (session == nil on entry).
    var activityMode: ActivityMode = .walking
    @ObservedObject var historyStore: WalkHistoryStore
    @ObservedObject var routeStore: CustomRouteStore

    @EnvironmentObject var petStore: PetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(ActiveWalkStore.self) private var walkStore

    /// Set once this view has had a session, started here or reopened. A
    /// session that then goes (Live Activity End) dismisses the screen; only
    /// a view that never had one starts a free walk. A guided walk, or any
    /// walk reopened from the mini tile, never set it until 2026-10-12, so
    /// ending one from the Live Activity started a free walk in its place.
    @State private var hasAttemptedStart = false

    var body: some View {
        if let session = walkStore.session, let route = walkStore.activeRoute {
            ActiveSessionScreen(session: session, route: route,
                                historyStore: historyStore, routeStore: routeStore)
                .onAppear { hasAttemptedStart = true }
        } else {
            // Session was cleared externally (Live Activity End) — or this is a new free session
            // that hasn't started yet.
            Color.clear
                .task {
                    guard !hasAttemptedStart else {
                        // Session already started and since cleared externally; dismiss cleanly.
                        dismiss()
                        return
                    }
                    hasAttemptedStart = true
                    let routeName: String
                    switch activityMode {
                    case .cycling: routeName = "Free Ride"
                    case .running: routeName = "Free Run"
                    default:       routeName = "Free Walk"
                    }
                    let stub = NavigableRoute(
                        name: routeName,
                        waypoints: [],
                        lapCount: 1,
                        isLoop: false,
                        totalDistance: 0,
                        isCustomRoute: true,
                        isCommunityRoute: false,
                        activityMode: activityMode,
                        customRouteId: nil
                    )
                    guard let session = walkStore.beginSession(route: stub) else { dismiss(); return }
                    walkStore.markStarted()
                    session.start()
                    for pet in petStore.activePets { session.petJoined(pet.id) }
                    await WalkLiveActivityManager.shared.start(
                        route: stub,
                        totalDistanceMeters: 0,
                        startDate: session.startTime
                    )
                }
        }
    }
}

/// The walk screen itself, for a session that exists.
///
/// `session` and `route` are values handed in by `ActiveSessionView`, not
/// read from the store. Until 2026-10-12 they were `walkStore.session!` and
/// `walkStore.activeRoute!`, on the reasoning that `body` checked the store
/// first. It does not hold: SwiftUI can update a `ForEach` row on its own,
/// without running `body` again. On 2026-10-12 a crew-row pet button's
/// accessibility label was updated after Done had cleared the store, read
/// `walkStore.activeRoute!` and trapped (crash report backtrace: `route`
/// getter <- `crewSection` <- `ForEachChild.updateValue`, during
/// `updatePreferences`). A value cannot be cleared from under a late
/// update: it is the walk that was on screen.
private struct ActiveSessionScreen: View {
    let session: NavigationSessionManager
    /// The store's current route; "Head back" and starting a trail from the
    /// way there replace it, and `ActiveSessionView` passes the new one in.
    let route: NavigableRoute
    @ObservedObject var historyStore: WalkHistoryStore
    @ObservedObject var routeStore: CustomRouteStore

    @EnvironmentObject var petStore: PetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(ActiveWalkStore.self) private var walkStore
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isGuided: Bool { !route.waypoints.isEmpty }

    // Shared state
    @State private var endSessionOnDismiss    = false
    @State private var showActivitySummary    = false
    @State private var summarySession: WalkSession?
    /// The trail this walk ended on (`ActiveWalkStore.endedTrail`; a trail
    /// reached from the way there sets it on arrival).
    @State private var summaryTrail: TrailRef?
    @State private var summaryPRs: [PRType]   = []
    @State private var summarySplits: [(label: String, elapsed: TimeInterval)] = []
    @State private var waterBreakEnabled      = false
    @State private var checkpointsEnabled     = false
    @State private var scheduledBreakCount    = 0
    @State private var showHeatBanner         = false
    @State private var walkWeather: RouteWeather? = nil
    @State private var summaryPetIds: [UUID] = []
    @State private var computedLegs: [RouteLeg] = []
    /// Bumped when the session turns a closed line round, once the legs for
    /// the new direction are ready: the map is rebuilt with its checkpoint pins
    /// numbered in the order they will now be walked.
    @State private var mapGeneration = 0
    @State private var showBreakPromptAlert   = false
    @State private var showDrivingBanner      = false
    @StateObject private var poiManager       = POIOverlayManager()
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showOwnerUpdateSheet   = false
    @State private var ownerUpdateRecipient: String? = nil
    @State private var ownerUpdateBody        = ""
    @State private var ownerUpdatePickerPets: [PetProfile] = []
    // Panel, finish and map orientation — redesign of 2026-09-24 (option B
    // of the "Active Walk Screen" canvas).
    @State private var panelExpanded          = false
    @State private var showFinishConfirm      = false
    @State private var pendingFinish: FinishChoice?
    @State private var headingUp              = false
    @State private var recenterToken          = 0
    @State private var headingTracker         = HeadingTracker()
    @State private var freeMapHeading: Double = 0
    @AppStorage("wkt_offTrailAlerts_v1") private var offTrailAlerts = true
    /// "Not now" on the arrived-at-the-trail banner. The offer stays in the
    /// pulled-up panel.
    @State private var trailArrivalDismissed  = false
    @State private var confirmHeadBack        = false

    private enum FinishChoice { case save, saveWithRoute, discard }

    /// A finish from this screen whose save failed: what Try again repeats.
    private struct FailedFinish { let saveRoute: Bool; let routeCompleted: Bool }
    @State private var failedFinish: FailedFinish?

    // MARK: - Body

    var body: some View {
        activeContent
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("session.root")
            // This full-screen cover does not inherit the tab view's limit
            // (SquatCounterApp): at Accessibility 5 the map's buttons and
            // icons kept growing (measured 2026-10-28), so the walk screen
            // sets the same limit itself.
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .toolbar(.hidden, for: .navigationBar)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .task { await startSession() }
            .onDisappear { if endSessionOnDismiss { walkStore.endSession() } }
            .onChange(of: checkpointsEnabled) { _, enabled in handleCheckpointToggle(enabled) }
            .onChange(of: session.isCompleted) { _, completed in
                guard completed, isGuided else { return }
                handleWalkComplete()
            }
            .onChange(of: session.totalDistanceCovered) { _, _ in session.pushLiveActivityState() }
            .onChange(of: Int(session.elapsedTime)) { _, elapsed in
                // Free sessions use elapsed-time ticks as an additional LA heartbeat.
                guard !isGuided, elapsed > 0, elapsed % 10 == 0 else { return }
                session.pushLiveActivityState()
            }
            .onChange(of: session.isPaused) { _, _ in session.pushLiveActivityState() }
            .onChange(of: petStore.activePets.count) { _, count in handlePetCountChange(count) }
            .onChange(of: session.showBreakPrompt) { _, show in
                // False when an auto-resume cleared the prompt.
                showBreakPromptAlert = show
            }
            .onChange(of: session.drivingSuspected) { _, suspected in
                if suspected { showDrivingBanner = true }
            }
            .onChange(of: session.trackPoints.count) { _, _ in
                guard !isGuided, let last = session.trackPoints.last else { return }
                poiManager.refreshIfNeeded(near: last)
            }
            .onChange(of: waterBreakEnabled) { _, enabled in
                guard enabled else { return }
                Task { await scheduleWaterBreakReminders() }
            }
            .modifier(BreakPromptAlert(
                isPresented: $showBreakPromptAlert,
                wording: route.wording,
                onEnd: {
                    session.dismissBreakPrompt()
                    if session.autoPausedForInactivity { session.resume() }
                    finishWalk()
                },
                onKeepTracking: {
                    session.dismissBreakPrompt()
                    if session.autoPausedForInactivity { session.resume() }
                }
            ))
            // A save that failed, from this screen or from elsewhere while it
            // is up (the app root's copy cannot show over this cover).
            .saveFailureAlert(
                noun: walkStore.saveFailure?.noun,
                onTryAgain: {
                    if let failed = failedFinish {
                        failedFinish = nil
                        finishWalk(saveRoute: failed.saveRoute, routeCompleted: failed.routeCompleted, retry: true)
                    } else {
                        walkStore.retrySave()
                    }
                },
                onKeepGoing: {
                    failedFinish = nil
                    walkStore.keepGoingAfterSaveFailure()
                })
    }

    // MARK: - Active Content

    @ViewBuilder private var activeContent: some View {
        ZStack(alignment: .bottom) {
            mapLayer
            hudPanel
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 10) {
                Button { dismiss() } label: {
                    Image(wkt: .chevronDown)
                        .wktIcon(.row, tint: .earthCream)
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Minimize session")
                .accessibilityIdentifier("session.minimize")
                MapOrientationControls(headingUp: $headingUp) { recenterToken += 1 }
            }
            .padding(.top, 60).padding(.leading, 16)
        }
        .onAppear {
            headingTracker.start()
            session.isSessionScreenVisible = true
        }
        .onDisappear {
            headingTracker.stop()
            session.isSessionScreenVisible = false
        }
        .onChange(of: headingUp) { _, up in
            position = .userLocation(followsHeading: up, fallback: .automatic)
        }
        .onChange(of: offTrailAlerts) { _, on in session.offTrailAlertsEnabled = on }
        .onChange(of: recenterToken) { _, _ in
            position = .userLocation(followsHeading: headingUp, fallback: .automatic)
        }
        .sheet(isPresented: $showFinishConfirm, onDismiss: runPendingFinish) {
            FinishConfirmationView(
                wording: route.wording,
                summary: finishSummary,
                onKeepGoing: { showFinishConfirm = false },
                onFinish: { pendingFinish = .save; showFinishConfirm = false },
                // A trail walk can't be saved as a route yet: MKDirections
                // would join its checkpoints on the streets (#63). A recorded
                // route saves its whole line, which RecordedRoute recognises.
                onFinishAndSaveRoute: isGuided && (route.path == nil || route.pathIsRecording)
                    ? { pendingFinish = .saveWithRoute; showFinishConfirm = false }
                    : nil,
                onDiscard: { pendingFinish = .discard; showFinishConfirm = false }
            )
        }
        .overlay(alignment: .topTrailing) {
            if !isGuided {
                poiChipsRow.padding(.top, 60).padding(.trailing, 16)
            }
        }
        .fullScreenCover(isPresented: $showActivitySummary, onDismiss: {
            // The summary's Done notes a record for the review prompt.
            endSessionOnDismiss = true
            dismiss()
        }) {
            if let s = summarySession {
                ActivitySummaryView(
                    session: s,
                    records: summaryPRs,
                    splits: summarySplits,
                    petIds: summaryPetIds,
                    onExcludeFromRouteStats: s.customRouteId != nil ? {
                        historyStore.updateCountsTowardRouteStats(id: s.id, counts: false)
                    } : nil,
                    trail: summaryTrail
                )
            }
        }
        .sheet(isPresented: $showOwnerUpdateSheet) {
            if let phone = ownerUpdateRecipient {
                MessageComposeSheet(recipients: [phone], body: ownerUpdateBody)
            }
        }
        .confirmationDialog("Head back to the start?", isPresented: $confirmHeadBack, titleVisibility: .visible) {
            Button("Head back now") { headBack() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("The rest of your \(route.wording.noun) follows \(route.name) back to where you started.")
        }
        .confirmationDialog("Send update to owner", isPresented: .init(
            get: { ownerUpdatePickerPets.count > 1 && !showOwnerUpdateSheet && !ownerUpdatePickerPets.isEmpty },
            set: { if !$0 { ownerUpdatePickerPets = [] } }
        ), titleVisibility: .visible) {
            ForEach(ownerUpdatePickerPets, id: \.id) { pet in
                Button(pet.ownerName ?? pet.name) { composeOwnerUpdate(for: pet) }
            }
        }
    }

    // MARK: - Map Layer

    @ViewBuilder private var mapLayer: some View {
        if isGuided {
            NavigationMapView(
                route: route,
                computedLegs: computedLegs,
                currentWaypointIndex: session.currentWaypointIndex,
                checkpointsEnabled: checkpointsEnabled,
                // Milestones are placed along this route's own line, so they
                // count from where it began, not from home.
                distanceCoveredMeters: session.totalDistanceCovered - session.legStartDistance,
                headingDegrees: headingTracker.direction(track: session.trackPoints),
                headingUp: headingUp,
                recenterToken: recenterToken,
                offTrailLink: offTrailLink
            )
            .id(mapGeneration)
            .ignoresSafeArea()
            .onChange(of: route.id) {
                Task {
                    computedLegs = await computeWalkingLegs()
                    mapGeneration += 1
                }
            }
        } else {
            Map(position: $position,
                bounds: MapCameraBounds(minimumDistance: 100, maximumDistance: 800)) {
                if session.trackPoints.count > 1 {
                    MapPolyline(coordinates: session.trackPoints)
                        .stroke(route.activityMode.tileColor, lineWidth: 5)
                }
                UserAnnotation {
                    UserHeadingDot(angle: headingTracker.direction(track: session.trackPoints)
                        .map { $0 - freeMapHeading })
                }
                ForEach(poiManager.pois) { poi in
                    Annotation("", coordinate: poi.coordinate, anchor: .bottom) {
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                poiManager.selectedPOI = (poiManager.selectedPOI?.id == poi.id) ? nil : poi
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(poi.category.color)
                                    .frame(width: 34, height: 34)
                                    .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                                Text(poi.category.emoji).font(.system(size: 17))
                            }
                            .overlay(
                                Circle().stroke(Color.white,
                                    lineWidth: poiManager.selectedPOI?.id == poi.id ? 2.5 : 0)
                            )
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                        }
                        .accessibilityLabel("\(poi.category.label): \(poi.name)")
                    }
                }
            }
            .mapStyle(.standard)
            .mapControls { MapCompass() }
            .onMapCameraChange(frequency: .continuous) { context in
                freeMapHeading = context.camera.heading
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - POI Chips Row (free sessions)

    private var poiChipsRow: some View {
        Menu {
            ForEach(WalkPOIFilter.allCases, id: \.rawValue) { cat in
                Toggle(isOn: Binding(
                    get: { poiManager.activeCategories.contains(cat) },
                    set: { isOn in
                        if isOn {
                            poiManager.enable(cat, near: session.trackPoints.last)
                        } else {
                            poiManager.disable(cat)
                        }
                    }
                )) {
                    Label {
                        Text(cat.label)
                    } icon: {
                        Text(cat.emoji)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(wkt: .place)
                    .wktIcon(.inline, tint: .earthCream)
                Text(poiFilterButtonLabel)
                    .font(.wktLabel)
                Image(wkt: .chevronDown)
                    .wktIcon(.inline, tint: .earthCream)
            }
            .foregroundColor(.earthCream)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
        }
    }

    private var poiFilterButtonLabel: String {
        let count = poiManager.activeCategories.count
        return count == 0 ? "Nearby" : "\(count) shown"
    }

    // Checkpoint indicator — adaptive so it doesn't go muddy in dark mode, matching the
    // treatment used for the shared design-system accent tokens. File-local because this
    // exact purple doesn't recur anywhere else in the app.
    private var checkpointAccent: Color {
        Color(UIColor { tc in tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.62, green: 0.48, blue: 0.88, alpha: 1)
            : UIColor(red: 0.35, green: 0.22, blue: 0.72, alpha: 1) })
    }

    // MARK: - HUD Panel

    private var hudPanel: some View {
        VStack(spacing: 0) {
            if showDrivingBanner {
                DrivingSuspectedBanner(
                    wording: route.wording,
                    onStillWalking: {
                        session.clearDrivingSuspicion()
                        showDrivingBanner = false
                    },
                    onEndWalk: {
                        showDrivingBanner = false
                        finishWalk()
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color.earthTrack)
                    .transition(.opacity)
            }
            if let progress = session.trailProgress, progress.isOffTrail {
                OffTrailBanner(trailName: route.name,
                               detail: session.offTrailDirectionText,
                               arrowAngle: offTrailArrowAngle)
                    .transition(.move(edge: .top).combined(with: .opacity))
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color.earthTrack)
            }
            if let approach = route.approach, session.arrivedAtTrail, !trailArrivalDismissed {
                TrailArrivalBanner(trailName: approach.trailName,
                                   wording: route.wording,
                                   onStart: startTrailFromApproach,
                                   onDismiss: { trailArrivalDismissed = true })
                    .transition(.move(edge: .top).combined(with: .opacity))
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color.earthTrack)
            }
            if showHeatBanner {
                HeatAdvisoryBanner(
                    intervalMinutes: waterBreakIntervalMinutes,
                    onEnableWaterBreaks: { waterBreakEnabled = true; showHeatBanner = false },
                    onDismiss: { showHeatBanner = false }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color.earthTrack)
                    .transition(.opacity)
            }

            panelHeader

            if session.isPaused {
                PauseResumeControl(
                    sessionLabel: route.wording.sessionLabel,
                    onResume: { session.resume() }
                )
            }

            if panelExpanded {
                ScrollView(showsIndicators: false) {
                    expandedDetails
                }
                .frame(maxHeight: SessionPanelLayout.expandedMaxHeight(typeSize))
                .transition(.opacity)
            } else {
                glanceStats
                    .transition(.opacity)
            }

            if !isGuided {
                if let poi = poiManager.selectedPOI {
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundColor(Color.earthTrack)
                    HStack(spacing: 12) {
                        Text(poi.category.emoji).font(.title2) // the place's category emoji (data)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(poi.name)
                                .font(.wktRowTitle)
                                .foregroundColor(.earthCream)
                                .lineLimit(1)
                            if let dist = distanceToUser(poi.coordinate) {
                                Text(dist).font(.wktLabel).foregroundColor(.earthMuted)
                            }
                        }
                        Spacer()
                        Button {
                            poi.mapItem.openInMaps(launchOptions: [
                                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
                            ])
                        } label: {
                            Image(wkt: .routes)
                                .wktIcon(.row, tint: .white, filled: true, onFill: true)
                                .padding(9)
                                .background(Color.earthGreenFill.opacity(0.9))
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("Show route")
                        Button {
                            withAnimation(.spring(response: 0.3)) { poiManager.selectedPOI = nil }
                        } label: {
                            Image(wkt: .dismiss)
                                .wktIcon(.inline, tint: .earthMuted)
                                .padding(9)
                                .background(Color.earthRaised, in: Circle())
                        }
                        .accessibilityLabel("Close \(poi.name) details")
                    }
                    .padding(14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            actionRow
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showDrivingBanner)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showHeatBanner)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: session.isPaused)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: session.estimatedSteps > 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: poiManager.selectedPOI?.id)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: panelExpanded)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: session.trailProgress?.isOffTrail)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: session.arrivedAtTrail)
        .background(.ultraThinMaterial, ignoresSafeAreaEdges: .bottom)
        // Its top edge is what the large-text UI test keeps below the map controls.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.panel")
    }

    // MARK: - Panel parts

    private var panelHeader: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)
            HStack(spacing: 8) {
                Image(wkt: route.activityMode.wktSymbol)
                    .wktIcon(.inline, tint: .earthGreen)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isGuided ? route.name : route.wording.sessionLabel)
                        .font(.wktRowTitle).foregroundColor(.earthCream)
                        .lineLimit(SessionPanelLayout.isLarge(typeSize) ? 2 : 1)
                    if isGuided {
                        // The activity's word first ("Hike · On the trail"):
                        // a guided title is the route's name, so this is
                        // where a walk, run, ride or hike says which it is.
                        Text("\(route.wording.sessionLabel) · \(session.progressText)")
                            .font(.wktLabel).foregroundColor(.earthGreen)
                    }
                }
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { panelExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(panelExpanded ? "Less" : "More")
                        Image(wkt: panelExpanded ? .chevronDown : .chevronUp)
                            .wktIcon(.inline, tint: .earthGreen)
                    }
                    .font(.wktBodyText)
                    .foregroundColor(.earthGreen)
                    .frame(minHeight: 44)
                }
                .accessibilityLabel(panelExpanded ? "Show fewer details" : "Show all stats and controls")
                .accessibilityIdentifier("session.more")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 12).onEnded { value in
            let expand = value.translation.height < -30
            let collapse = value.translation.height > 30
            guard expand != panelExpanded, expand || collapse else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { panelExpanded = expand }
        })
    }

    /// The default view: three numbers that matter mid-walk, so the map keeps the screen.
    private var glanceStats: some View {
        VStack(spacing: 10) {
            // Three across; at the accessibility sizes distance and time
            // share a row and the pace takes the next, so no word is cut.
            if SessionPanelLayout.statColumns(typeSize) < 3 {
                HStack(spacing: 8) { glanceDistance; glanceTime }
                glancePace
            } else {
                HStack(spacing: 8) { glanceDistance; glanceTime; glancePace }
            }
            if isGuided { routeProgress }
            if session.canHeadBack {
                HStack {
                    Spacer()
                    WktPillButton(title: "Head back now", tint: .earthGreen) { confirmHeadBack = true }
                        .accessibilityIdentifier("session.headBack")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    private var glanceDistance: some View {
        SessionStatTile(value: session.distanceText(session.totalDistanceCovered),
                        label: "distance", prominent: true)
    }

    private var glanceTime: some View {
        SessionStatTile(value: session.elapsedText, label: "time", prominent: true)
            .accessibilityIdentifier("session.elapsed")
    }

    /// A walk or run glances at its current pace; a ride at its speed.
    @ViewBuilder private var glancePace: some View {
        if showsCurrentPace {
            SessionStatTile(value: session.currentPaceText, label: "current pace", prominent: true)
                .accessibilityIdentifier("session.currentPace")
        } else {
            SessionStatTile(value: session.paceText, label: session.paceLabel, prominent: true)
        }
    }

    /// Pulled up: every stat the session tracks, and each control with what it does.
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isGuided { routeProgress }
            if session.canHeadBack {
                WktSecondaryButton(title: "Head back now", symbol: .undo) { confirmHeadBack = true }
                    .accessibilityIdentifier("session.headBackExpanded")
            }
            if let approach = route.approach, session.arrivedAtTrail {
                WktPrimaryButton(title: "Start the \(approach.trailName) \(route.wording.noun)",
                                 symbol: .routeTrail, action: startTrailFromApproach)
                    .accessibilityIdentifier("session.startTrail")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                     count: SessionPanelLayout.statColumns(typeSize)), spacing: 8) {
                SessionStatTile(value: session.distanceText(session.totalDistanceCovered), label: "distance")
                if isGuided {
                    SessionStatTile(value: session.distanceText(session.remainingDistance), label: "remaining")
                }
                SessionStatTile(value: session.elapsedText, label: "time")
                    .accessibilityIdentifier("session.elapsed")
                if showsCurrentPace {
                    SessionStatTile(value: session.currentPaceText, label: "current pace")
                }
                SessionStatTile(value: session.paceText, label: session.paceLabel)
                    .accessibilityIdentifier("session.averagePace")
                if showsSteps {
                    SessionStatTile(value: session.estimatedSteps.formatted(), label: "steps")
                }
                if let cadence = session.cadence, cadence > 0 {
                    SessionStatTile(value: "\(Int(cadence))", label: "steps / min")
                }
                if isGuided {
                    SessionStatTile(value: session.distanceText(session.distanceToNextWaypoint), label: "to next")
                }
                if isGuided, let eta = session.estimatedSecondsRemaining {
                    SessionStatTile(value: durationText(eta), label: "est. left")
                }
                SessionStatTile(value: "\(session.stopCount)", label: "stops")
                    .accessibilityIdentifier("session.stops")
            }

            VStack(spacing: 2) {
                SessionToggleRow(icon: .speakerOn, tint: .earthGreen, title: "Voice cues",
                                 detail: "Announces each \(WalkAudioCueService.usesMiles ? "mile" : "kilometer"), its time and your average",
                                 isOn: Binding(get: { WalkAudioCueService.shared.isEnabled },
                                               set: { WalkAudioCueService.shared.isEnabled = $0 }))
                SessionToggleRow(icon: .hydration, tint: .accentInfo, title: "Water breaks",
                                 detail: "A reminder to drink every \(waterBreakIntervalMinutes) min",
                                 isOn: Binding(get: { waterBreakEnabled },
                                               set: { on in
                                                   waterBreakEnabled = on
                                                   if !on { cancelWaterBreakReminders() }
                                               }))
                if isGuided {
                    SessionToggleRow(icon: .finish, tint: checkpointAccent, title: "Checkpoint markers",
                                     detail: route.isCustomRoute ? "Marks each waypoint on the map"
                                                                 : "Marks every 20% of the route on the map",
                                     isOn: $checkpointsEnabled)
                }
                if route.path != nil {
                    SessionToggleRow(icon: .directionArrow, tint: .earthOrange, title: "Off-\(route.lineNoun) alerts",
                                     detail: "Tells you when you're more than \(session.distanceText(OffTrailMonitor.leaveMeters)) from the \(route.lineNoun), and which way it is",
                                     isOn: $offTrailAlerts)
                }
            }

            if !petStore.pets.isEmpty { crewSection }

            if !isGuided {
                let activePetsWithOwner = petStore.activePets.filter { $0.ownerPhone != nil }
                if !activePetsWithOwner.isEmpty && MFMessageComposeViewController.canSendText() {
                    Button {
                        if activePetsWithOwner.count == 1 {
                            composeOwnerUpdate(for: activePetsWithOwner[0])
                        } else {
                            ownerUpdatePickerPets = activePetsWithOwner
                        }
                    } label: {
                        Label {
                            Text("Send the owner an update")
                        } icon: {
                            Image(wkt: .chat).wktIcon(.row, tint: .earthGreen)
                        }
                        .font(.wktBodyText)
                        .foregroundColor(.earthGreen)
                        .frame(minHeight: 44)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// From the person to the nearest point of the trail, while they are off it.
    private var offTrailLink: [CLLocationCoordinate2D]? {
        guard let progress = session.trailProgress, progress.isOffTrail,
              let nearest = progress.nearest, let here = session.trackPoints.last else { return nil }
        return [here, nearest]
    }

    /// The way back to the trail relative to where the person faces.
    private var offTrailArrowAngle: Double? {
        guard let bearing = session.bearingToTrail,
              let facing = headingTracker.direction(track: session.trackPoints) else { return nil }
        return bearing - facing
    }

    private var routeProgress: some View {
        let total = route.totalDistance * Double(max(1, route.lapCount))
        let covered = max(0, total - session.remainingDistance)
        return SessionProgressBar(covered: covered, total: total,
                                  coveredText: "\(session.distanceText(covered)) done",
                                  totalText: session.distanceText(total))
    }

    private var crewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Crew on this \(route.wording.noun)")
                .font(.wktRowTitle)
                .foregroundColor(.earthCream)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(petStore.pets) { pet in
                        Button { togglePet(pet) } label: {
                            HStack(spacing: 6) {
                                Text(pet.displayEmoji)
                                Text(pet.name).font(.wktLabel)
                            }
                            .foregroundColor(pet.isActiveOnWalk ? .white : .earthCream)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            // The shared "chosen" look, as a capsule.
                            .background(pet.isActiveOnWalk ? Color.earthGreenFill : Color.earthRaised, in: Capsule())
                        }
                        .accessibilityLabel(pet.isActiveOnWalk
                            ? "Remove \(pet.name) from \(route.wording.noun)"
                            : "Add \(pet.name) to \(route.wording.noun)")
                        .accessibilityAddTraits(pet.isActiveOnWalk ? .isSelected : [])
                    }
                }
            }
        }
    }

    /// Pause is the big, easy target; Finish needs a hold, then a confirmation.
    /// At the accessibility sizes Pause sits above Finish, each the full
    /// width: beside Pause, 140 pt cut "Hold to finish" to "Hold to fi…".
    private var actionRow: some View {
        let stacked = SessionPanelLayout.stacksActions(typeSize)
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Button {
                if session.isPaused { session.resume() } else { session.pause() }
            } label: {
                WktPrimaryLabel(title: session.isPaused ? "Resume" : "Pause",
                                symbol: session.isPaused ? .play : .pause)
            }
            .buttonStyle(BounceButtonStyle(scale: 0.98))
            .accessibilityLabel(session.isPaused
                ? "Resume \(route.wording.noun)"
                : "Pause \(route.wording.noun)")
            .accessibilityIdentifier("session.pause")

            HoldToFinishButton(wording: route.wording) { showFinishConfirm = true }
                .frame(width: stacked ? nil : 140)
                .accessibilityIdentifier("session.finish")
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private func togglePet(_ pet: PetProfile) {
        let willActivate = !pet.isActiveOnWalk
        petStore.setActive(pet.id, active: willActivate)
        if willActivate { session.petJoined(pet.id) } else { session.petLeft(pet.id) }
    }

    private func durationText(_ t: TimeInterval) -> String {
        let s = Int(t); let m = s / 60
        return m < 60 ? "\(m)m \(s % 60)s" : "\(m / 60)h \(m % 60)m"
    }

    // MARK: - Heading to a trail

    /// "Head back now": the rest of the walk becomes the trail back to where
    /// it started (`NavigationSessionManager.headBack`). Same session; the
    /// Live Activity is restarted for the new route and given the walk's
    /// numbers at once, as when a trail starts from the way there, or it
    /// would show zeros until the next fix (critic review of #163).
    private func headBack() {
        guard let next = session.headBack() else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let cap = session
        Task {
            await WalkLiveActivityManager.shared.start(
                route: next,
                totalDistanceMeters: cap.liveActivityTotalMeters,
                startDate: cap.startTime
            )
            await WalkLiveActivityManager.shared.update(cap.liveActivityState)
        }
    }

    /// The person reached the trail they were heading for and wants to walk
    /// it: the same session carries on along the trail
    /// (`NavigationSessionManager.beginTrailWalk`). `onChange(of: route.id)`
    /// redraws the map; the Live Activity is restarted because its route name
    /// is fixed when it starts.
    private func startTrailFromApproach() {
        guard let next = session.beginTrailWalk() else { return }
        trailArrivalDismissed = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        WalkAudioCueService.shared.announce("Starting \(next.name).")
        let cap = session
        Task {
            await WalkLiveActivityManager.shared.start(
                route: next,
                totalDistanceMeters: cap.liveActivityTotalMeters,
                startDate: cap.startTime
            )
            await WalkLiveActivityManager.shared.update(cap.liveActivityState)
        }
    }

    // MARK: - Finishing

    /// Walks and runs show a smoothed current pace beside the average; a ride
    /// shows one average speed (`feat/run-pace-splits`).
    private var showsCurrentPace: Bool { route.activityMode.hasPaceAndSplits }

    /// A ride's steps are only distance / 0.762 m: not shown.
    private var showsSteps: Bool {
        session.estimatedSteps > 0 && ActivitySummaryContent.showsSteps(for: route.activityMode)
    }

    private var finishSummary: String {
        var parts = [session.distanceText(session.totalDistanceCovered), session.elapsedText]
        if showsSteps { parts.append("\(session.estimatedSteps.formatted()) steps") }
        return parts.joined(separator: " · ")
    }

    /// Runs after the confirmation sheet has gone, so the summary's
    /// full-screen cover is not presented on top of a dismissing sheet.
    private func runPendingFinish() {
        guard let choice = pendingFinish else { return }
        pendingFinish = nil
        switch choice {
        case .save:
            finishWalk()
        case .saveWithRoute:
            finishWalk(saveRoute: true)
        case .discard:
            discardSession()
        }
    }

    /// Every save from this screen: Finish, the break prompt, the driving
    /// banner and route completion. The store ends the walk (history with pet
    /// credit, Health workout, Live Activity, water breaks, checkpoint) and
    /// keeps the stopped session until the summary goes away. Only a route
    /// completed on foot announces a record and schedules the hydration nudge.
    ///
    /// A save that fails leaves the walk going and this screen up, with
    /// "Couldn't save" (`failedFinish`); Try again runs this again through
    /// the store's `retrySave`. The route is saved to My Routes only once the
    /// walk is, so a retry cannot save it twice.
    private func finishWalk(saveRoute: Bool = false, routeCompleted: Bool = false, retry: Bool = false) {
        let previous = historyStore.sessions
        summarySplits = session.splitTimes
        let saved = retry ? walkStore.retrySave() : walkStore.end(.save, releaseSession: false)
        if saved == nil, walkStore.saveFailure != nil {
            failedFinish = FailedFinish(saveRoute: saveRoute, routeCompleted: routeCompleted)
            return
        }
        if saveRoute { saveCurrentRoute() }
        summaryTrail = walkStore.endedTrail
        let prs = saved.map { checkNewPRs(newSession: $0, against: previous) } ?? []
        if routeCompleted, let saved {
            if !prs.isEmpty {
                WalkAudioCueService.shared.announce(
                    "Personal record! New \(prs.map(\.title).joined(separator: " and "))!")
            }
            scheduleHydrationNudge(distanceMeters: saved.totalDistance)
        }
        showSummary(saved: saved, prList: prs)
    }

    private func discardSession() {
        walkStore.end(.discard, releaseSession: false)
        endSessionOnDismiss = true
        dismiss()
    }

    // MARK: - Session Start

    private func startSession() async {
        guard !walkStore.isStarted else {
            // Re-presenting after minimize — recompute display data without restarting.
            if isGuided {
                computedLegs = await computeWalkingLegs()
                if let firstWaypoint = route.waypoints.first {
                    walkWeather = await RouteWeatherService.shared.fetchWeather(for: firstWaypoint)
                }
            }
            session.onCheckpointReached = checkpointsEnabled ? { [self] lbl in handleCheckpoint(lbl) } : nil
            session.offTrailAlertsEnabled = offTrailAlerts
            session.onOffTrailChange = { off in
                UINotificationFeedbackGenerator().notificationOccurred(off ? .warning : .success)
            }
            showBreakPromptAlert = session.showBreakPrompt
            showDrivingBanner = session.drivingSuspected
            // Adopt pets that became active while minimized; the session kept
            // the credit of those already on the walk.
            for pet in petStore.activePets { session.petJoined(pet.id) }
            return
        }
        // Free sessions are started in the else-branch task; guided sessions start here.
        guard isGuided else { return }

        walkStore.markStarted()
        // Quiet delivery only — the real prompt is Settings' job now. Skipped under
        // -WKTUITest for the same reason as at launch: a granted (even provisional)
        // status lets session banners render in the simulator, and a banner wakes
        // the smoke tests' interruption monitor mid-tap (Xcode Cloud, 2026-09-09).
        // Also under -WKTDemo, so a walk in a how-to recording raises no banners.
        if !isWKTUITestMode, !isWKTDemoMode {
            await NotificationService.shared.requestQuietDeliveryIfNeverAsked()
        }
        for pet in petStore.activePets { session.petJoined(pet.id) }
        WalkAudioCueService.shared.reset()
        session.start()
        session.onCheckpointReached = checkpointsEnabled ? { [self] lbl in handleCheckpoint(lbl) } : nil
        session.offTrailAlertsEnabled = offTrailAlerts
        session.onOffTrailChange = { off in
            UINotificationFeedbackGenerator().notificationOccurred(off ? .warning : .success)
        }
        await WalkLiveActivityManager.shared.start(
            route: route,
            totalDistanceMeters: session.liveActivityTotalMeters,
            startDate: session.startTime
        )
        computedLegs = await computeWalkingLegs()
        if let firstWaypoint = route.waypoints.first {
            walkWeather = await RouteWeatherService.shared.fetchWeather(for: firstWaypoint)
        }
        if let w = walkWeather, w.temperatureCelsius > 27, !petStore.activePets.isEmpty {
            showHeatBanner = true
        }
    }

    // MARK: - End Helpers

    /// A guided walk reached its end with this screen up. With the screen
    /// closed, the store ends it itself (`ActiveWalkStore.sessionDidComplete`).
    private func handleWalkComplete() {
        finishWalk(routeCompleted: true)
    }

    private func showSummary(saved: WalkSession?, prList: [PRType]) {
        summaryPRs = prList
        summaryPetIds = Array(session.sessionPetIds)
        summarySession = saved
        endSessionOnDismiss = true
        if saved != nil {
            showActivitySummary = true
        } else {
            dismiss()
        }
    }

    // MARK: - Checkpoint

    private func handleCheckpointToggle(_ enabled: Bool) {
        session.onCheckpointReached = enabled ? { [self] lbl in handleCheckpoint(lbl) } : nil
    }

    private func handleCheckpoint(_ label: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        guard checkpointsEnabled else { return }
        Task {
            await NotificationService.shared.schedule(.checkpoint(label), title: "Checkpoint \(label) 🎯", body: "Keep it up!",
                                                      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false))
        }
    }

    // MARK: - Pet Count Change

    private func handlePetCountChange(_ count: Int) {
        if count == 0 {
            showHeatBanner = false
            if waterBreakEnabled { cancelWaterBreakReminders(); waterBreakEnabled = false }
        } else if let w = walkWeather, w.temperatureCelsius > 27 {
            showHeatBanner = true
        }
    }

    // MARK: - Utilities

    private func saveCurrentRoute() {
        routeStore.save(CustomRoute(
            id: UUID(),
            name: route.name,
            waypoints: route.historyWaypoints.map { WaypointCoord($0) },
            totalDistance: route.totalDistance,
            isLoop: route.isLoop,
            createdAt: Date(),
            activityMode: route.activityMode
        ))
    }

    private func composeOwnerUpdate(for pet: PetProfile) {
        guard let phone = pet.ownerPhone, MFMessageComposeViewController.canSendText() else { return }
        let dist = MKDistanceFormatter.abbreviated.string(fromDistance: session.totalDistanceCovered)
        let petDist = MKDistanceFormatter.abbreviated.string(fromDistance: session.petDistances[pet.id] ?? 0)
        let ownerFirst = pet.ownerName?.components(separatedBy: " ").first ?? "there"
        ownerUpdateBody = "Hi \(ownerFirst)! Currently \(route.wording.gerund) with \(pet.name) 🐾\n\n📏 \(petDist) so far (total: \(dist))\n\nSent from Wockett"
        ownerUpdateRecipient = phone
        ownerUpdatePickerPets = []
        showOwnerUpdateSheet = true
    }

    private func distanceToUser(_ coord: CLLocationCoordinate2D) -> String? {
        guard let last = session.trackPoints.last else { return nil }
        let dist = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
        return MKDistanceFormatter.abbreviated.string(fromDistance: dist) + " away"
    }

    private func scheduleHydrationNudge(distanceMeters: Double) {
        let distKm = distanceMeters / 1000
        let body = distKm >= 5
            ? "Great \(String(format: "%.1f", distKm))km \(route.wording.noun) — drink at least 500ml of water to recover well."
            : "Good \(route.wording.noun) — remember to drink some water to keep your energy up."
        Task {
            await NotificationService.shared.schedule(.hydration, title: "Time to rehydrate! 💧", body: body,
                                                      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 300, repeats: false))
        }
    }

    // MARK: - Water Breaks

    private var waterBreakIntervalMinutes: Int {
        let temp = walkWeather?.temperatureCelsius ?? 20
        if temp > 32 { return 10 }
        if temp > 27 { return 15 }
        return 20
    }

    private func scheduleWaterBreakReminders() async {
        // The user asked for these — a legitimate moment for the real prompt.
        let notifications = NotificationService.shared
        await notifications.refreshStatus()
        if !notifications.isFullyAuthorized {
            guard await notifications.requestFullAuthorization() else { return }
        }
        let intervalSecs = Double(waterBreakIntervalMinutes) * 60
        let durationMins = route.totalDistance > 0 ? route.totalDistance / 1.4 / 60 : 60
        let count = min(12, max(1, Int(ceil(durationMins / Double(waterBreakIntervalMinutes)))))
        scheduledBreakCount = count
        let body = petStore.activePets.isEmpty
            ? "Time for a water break."
            : "Time to hydrate — your \(petStore.activePets.count == 1 ? "pup" : "pups") need water too."
        for i in 1...count {
            await notifications.schedule(.waterBreak(i), title: "Water break! 💧", body: body,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: Double(i) * intervalSecs, repeats: false))
        }
    }

    private func cancelWaterBreakReminders() {
        NotificationService.shared.cancelWaterBreaks()
        scheduledBreakCount = 0
    }

    // MARK: - Route Computation

    private func computeWalkingLegs() async -> [RouteLeg] {
        // A trail walk follows its own line; MKDirections would route it on
        // the streets beside the trail.
        if let path = route.path, path.count >= 2 { return [RouteLeg(path: path)] }
        let wps = route.waypoints
        guard wps.count >= 2 else { return [] }
        var legs: [RouteLeg] = []
        let legCount = route.isLoop ? wps.count : wps.count - 1
        for i in 0..<legCount {
            let from = wps[i], to = wps[(i + 1) % wps.count]
            let req = MKDirections.Request()
            req.source        = MKMapItem(location: CLLocation(latitude: from.latitude, longitude: from.longitude), address: nil)
            req.destination   = MKMapItem(location: CLLocation(latitude: to.latitude, longitude: to.longitude), address: nil)
            req.transportType = route.activityMode.transportType
            if let r = try? await MKDirections(request: req).calculate().routes.first {
                legs.append(RouteLeg(r))
            }
        }
        return legs
    }

    // MARK: - POI Chip

}

// MARK: - Heat Advisory Banner

private struct HeatAdvisoryBanner: View {
    let intervalMinutes: Int
    let onEnableWaterBreaks: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        WktBanner(symbol: .heat, tint: .earthOrange,
                  title: "Heat advisory",
                  detail: "Hot pavement can burn paws. Keep pets hydrated.") {
            WktPillButton(title: "Water break every \(intervalMinutes) min", tint: .accentInfo, action: onEnableWaterBreaks)
            WktPillButton(title: "Dismiss", tint: .earthCream, action: onDismiss)
                .accessibilityLabel("Dismiss heat advisory")
        }
    }
}
