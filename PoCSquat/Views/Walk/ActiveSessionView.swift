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

    // Both unwraps are guarded by `body`, which renders nothing unless
    // `walkStore.session != nil`, and ActiveWalkStore writes/clears `session` and
    // `activeRoute` together at every site (beginSession, restoreIfNeeded,
    // endSession). The store is @MainActor and body evaluates synchronously on it,
    // so there is no window between the check and these reads. The invariant is
    // real; it just wasn't written down until 2026-09-08.
    // swiftlint:disable:next force_unwrapping
    private var session: NavigationSessionManager { walkStore.session! }
    // swiftlint:disable:next force_unwrapping
    private var route: NavigableRoute { walkStore.activeRoute! }
    private var isGuided: Bool { !(walkStore.activeRoute?.waypoints.isEmpty ?? true) }

    // Shared state
    @State private var endSessionOnDismiss    = false
    @State private var showActivitySummary    = false
    @State private var summarySession: WalkSession?
    @State private var summaryPRs: [PRType]   = []
    @State private var summarySplits: [(label: String, elapsed: TimeInterval)] = []
    @State private var waterBreakEnabled      = false
    @State private var checkpointsEnabled     = false
    @State private var scheduledBreakCount    = 0
    @State private var showHeatBanner         = false
    @State private var walkWeather: RouteWeather? = nil
    @State private var petCompletions: [PetCompletion] = []
    @State private var completedPetNames: [String] = []
    @State private var computedLegs: [RouteLeg] = []
    @State private var petActiveSinceDistance: [UUID: Double] = [:]
    @State private var petAccumulatedDistances: [UUID: Double] = [:]
    @State private var allSessionPetIds: Set<UUID> = []
    @State private var showBreakPromptAlert   = false
    @State private var showDrivingBanner      = false
    // Free-session specific state
    @State private var hasAttemptedStart      = false
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

    private enum FinishChoice { case save, saveWithRoute, discard }

    // MARK: - Body

    var body: some View {
        if walkStore.session != nil {
            activeContent
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("session.root")
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
                .onChange(of: session.totalDistanceCovered) { _, dist in
                    let elapsed = session.elapsedTime
                    let isPaused = session.isPaused
                    let pace = dist > 100 && elapsed > 10 ? elapsed / (dist / 1000) : nil
                    Task {
                        await WalkLiveActivityManager.shared.update(
                            distanceCovered: dist,
                            elapsedSeconds: Int(elapsed),
                            isPaused: isPaused,
                            paceSecsPerKm: pace,
                            pausedDuration: session.totalPausedDuration,
                            pauseTime: isPaused ? Date() : nil
                        )
                    }
                }
                .onChange(of: Int(session.elapsedTime)) { _, elapsed in
                    // Free sessions use elapsed-time ticks as an additional LA heartbeat.
                    guard !isGuided, elapsed > 0, elapsed % 10 == 0 else { return }
                    let dist = session.totalDistanceCovered
                    let paused = session.isPaused
                    let pace: Double? = dist > 50 ? Double(elapsed) / (dist / 1_000) : nil
                    Task {
                        await WalkLiveActivityManager.shared.update(
                            distanceCovered: dist,
                            elapsedSeconds: elapsed,
                            isPaused: paused,
                            paceSecsPerKm: pace,
                            pausedDuration: session.totalPausedDuration,
                            pauseTime: paused ? Date() : nil
                        )
                    }
                }
                .onChange(of: session.isPaused) { _, paused in
                    let dist = session.totalDistanceCovered
                    let elapsed = session.elapsedTime
                    let pace = dist > 100 && elapsed > 10 ? elapsed / (dist / 1000) : nil
                    Task {
                        await WalkLiveActivityManager.shared.update(
                            distanceCovered: dist,
                            elapsedSeconds: Int(elapsed),
                            isPaused: paused,
                            paceSecsPerKm: pace,
                            pausedDuration: session.totalPausedDuration,
                            pauseTime: paused ? Date() : nil
                        )
                    }
                }
                .onChange(of: petStore.activePets.count) { _, count in handlePetCountChange(count) }
                .onChange(of: session.showBreakPrompt) { _, show in
                    if show { showBreakPromptAlert = true }
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
                    activityMode: route.activityMode,
                    onEnd: {
                        session.dismissBreakPrompt()
                        if session.autoPausedForInactivity { session.resume() }
                        if isGuided {
                            let pets = finalizePetDistances()
                            let prev = historyStore.sessions
                            let saved = walkStore.buildAndSaveSession(
                                petDistances: pets.distances,
                                activePetIds: pets.activePetIds,
                                isCommunityRoute: route.isCommunityRoute
                            )
                            let cap = session
                            let dist = cap.totalDistanceCovered
                            let elapsed = Int(cap.elapsedTime)
                            let paused = cap.totalPausedDuration
                            Task {
                                await WalkLiveActivityManager.shared.end(distanceCovered: dist, elapsedSeconds: elapsed, pausedDuration: paused)
                                await cap.finishWorkoutSession()
                            }
                            let prs = saved.map { checkNewPRs(newSession: $0, against: prev) } ?? []
                            finishAndShowSummary(saved: saved, prList: prs)
                        } else {
                            endFreeSession()
                        }
                    },
                    onKeepTracking: {
                        session.dismissBreakPrompt()
                        if session.autoPausedForInactivity { session.resume() }
                    }
                ))
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
                    guard walkStore.beginSession(route: stub) != nil else { dismiss(); return }
                    walkStore.markStarted()
                    session.start()
                    for pet in petStore.activePets {
                        petActiveSinceDistance[pet.id] = 0
                        allSessionPetIds.insert(pet.id)
                    }
                    await WalkLiveActivityManager.shared.start(
                        routeName: stub.name,
                        totalDistanceMeters: 0,
                        activityMode: activityMode.rawValue,
                        startDate: session.startTime
                    )
                }
        }
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
        .onAppear { headingTracker.start() }
        .onDisappear { headingTracker.stop() }
        .onChange(of: headingUp) { _, up in
            position = .userLocation(followsHeading: up, fallback: .automatic)
        }
        .onChange(of: recenterToken) { _, _ in
            position = .userLocation(followsHeading: headingUp, fallback: .automatic)
        }
        .sheet(isPresented: $showFinishConfirm, onDismiss: runPendingFinish) {
            FinishConfirmationView(
                activityMode: route.activityMode,
                summary: finishSummary,
                onKeepGoing: { showFinishConfirm = false },
                onFinish: { pendingFinish = .save; showFinishConfirm = false },
                // A trail walk can't be saved as a route yet: MKDirections
                // would join its checkpoints on the streets (#63).
                onFinishAndSaveRoute: isGuided && route.path == nil
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
            cancelWaterBreakReminders()
            endSessionOnDismiss = true
            dismiss()
        }) {
            if let s = summarySession {
                ActivitySummaryView(
                    session: s,
                    newPRs: summaryPRs,
                    splits: summarySplits,
                    petCompletions: petCompletions,
                    petNames: completedPetNames,
                    onExcludeFromRouteStats: s.customRouteId != nil ? {
                        historyStore.updateCountsTowardRouteStats(id: s.id, counts: false)
                    } : nil,
                    historyStore: historyStore,
                    routeStore: routeStore
                )
            }
        }
        .sheet(isPresented: $showOwnerUpdateSheet) {
            if let phone = ownerUpdateRecipient {
                MessageComposeSheet(recipients: [phone], body: ownerUpdateBody)
            }
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
                distanceCoveredMeters: session.totalDistanceCovered,
                headingDegrees: headingTracker.direction(track: session.trackPoints),
                headingUp: headingUp,
                recenterToken: recenterToken
            )
            .ignoresSafeArea()
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
                    .font(.wktBody(12))
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
                    activityMode: route.activityMode,
                    onStillWalking: {
                        session.clearDrivingSuspicion()
                        showDrivingBanner = false
                    },
                    onEndWalk: {
                        showDrivingBanner = false
                        if isGuided {
                            let cap = session
                            let paused = cap.totalPausedDuration
                            cap.stop()
                            Task {
                                await WalkLiveActivityManager.shared.end(
                                    distanceCovered: cap.totalDistanceCovered,
                                    elapsedSeconds: Int(cap.elapsedTime),
                                    pausedDuration: paused
                                )
                            }
                            handleWalkComplete()
                        } else {
                            endFreeSession()
                        }
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color.earthMuted.opacity(0.25))
                    .transition(.opacity)
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
                    .foregroundColor(Color.earthMuted.opacity(0.25))
                    .transition(.opacity)
            }

            panelHeader

            if session.isPaused {
                PauseResumeControl(
                    sessionLabel: route.activityMode.sessionLabel,
                    onResume: { session.resume() }
                )
            }

            if panelExpanded {
                ScrollView(showsIndicators: false) {
                    expandedDetails
                }
                .frame(maxHeight: 430)
                .transition(.opacity)
            } else {
                glanceStats
                    .transition(.opacity)
            }

            if !isGuided {
                if let poi = poiManager.selectedPOI {
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundColor(Color.earthMuted.opacity(0.25))
                    HStack(spacing: 12) {
                        Text(poi.category.emoji).font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(poi.name)
                                .font(.wktHeading(14))
                                .foregroundColor(.earthCream)
                                .lineLimit(1)
                            if let dist = distanceToUser(poi.coordinate) {
                                Text(dist).wktTechnical(10).foregroundColor(.earthMuted)
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
                                .background(Color.earthCard)
                                .clipShape(Circle())
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
        .background(.ultraThinMaterial, ignoresSafeAreaEdges: .bottom)
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
                    Text(isGuided ? route.name : route.activityMode.sessionLabel)
                        .font(.wktHeading(15)).foregroundColor(.earthCream).lineLimit(1)
                    if isGuided {
                        Text(session.progressText)
                            .font(.wktBody(12)).foregroundColor(.earthGreen)
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
                    .font(.subheadline.bold())
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
            HStack(spacing: 8) {
                SessionStatTile(value: session.distanceText(session.totalDistanceCovered),
                                label: "distance", prominent: true)
                SessionStatTile(value: session.elapsedText, label: "time", prominent: true)
                    .accessibilityIdentifier("session.elapsed")
                SessionStatTile(value: session.paceText, label: session.paceLabel, prominent: true)
            }
            if isGuided { routeProgress }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    /// Pulled up: every stat the session tracks, and each control with what it does.
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isGuided { routeProgress }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                SessionStatTile(value: session.distanceText(session.totalDistanceCovered), label: "distance")
                if isGuided {
                    SessionStatTile(value: session.distanceText(session.remainingDistance), label: "remaining")
                }
                SessionStatTile(value: session.elapsedText, label: "time")
                    .accessibilityIdentifier("session.elapsed")
                SessionStatTile(value: session.paceText, label: session.paceLabel)
                if session.estimatedSteps > 0 {
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
            }

            VStack(spacing: 2) {
                SessionToggleRow(icon: .speakerOn, tint: .earthGreen, title: "Voice cues",
                                 detail: "Announces each \(Locale.current.measurementSystem == .us ? "mile" : "kilometer") and your pace",
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
                        .font(.subheadline.bold())
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

    private var routeProgress: some View {
        let total = route.totalDistance * Double(max(1, route.lapCount))
        let covered = max(0, total - session.remainingDistance)
        return SessionProgressBar(covered: covered, total: total,
                                  coveredText: "\(session.distanceText(covered)) done",
                                  totalText: session.distanceText(total))
    }

    private var crewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Crew on this \(route.activityMode.noun)")
                .font(.subheadline.bold())
                .foregroundColor(.earthCream)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(petStore.pets) { pet in
                        Button { togglePet(pet) } label: {
                            HStack(spacing: 6) {
                                Text(pet.displayEmoji)
                                Text(pet.name).font(.subheadline.bold())
                            }
                            .foregroundColor(pet.isActiveOnWalk ? .earthCream : .earthMuted)
                            .padding(.horizontal, 12)
                            .frame(height: 40)
                            .background(pet.isActiveOnWalk ? Color.earthGreen.opacity(0.15) : Color.earthCard)
                            .overlay(Capsule().stroke(pet.isActiveOnWalk ? Color.earthGreen : Color.clear, lineWidth: 1.5))
                            .clipShape(Capsule())
                        }
                        .accessibilityLabel(pet.isActiveOnWalk
                            ? "Remove \(pet.name) from \(route.activityMode.noun)"
                            : "Add \(pet.name) to \(route.activityMode.noun)")
                        .accessibilityAddTraits(pet.isActiveOnWalk ? .isSelected : [])
                    }
                }
            }
        }
    }

    /// Pause is the big, easy target; Finish needs a hold, then a confirmation.
    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                if session.isPaused { session.resume() } else { session.pause() }
            } label: {
                Label {
                    Text(session.isPaused ? "Resume" : "Pause")
                } icon: {
                    Image(wkt: session.isPaused ? .play : .pause)
                        .wktIcon(.row, tint: .white, filled: true, onFill: true)
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.earthGreenFill)
                .foregroundColor(.white)
                .cornerRadius(14)
            }
            .accessibilityLabel(session.isPaused
                ? "Resume \(route.activityMode.noun)"
                : "Pause \(route.activityMode.noun)")
            .accessibilityIdentifier("session.pause")

            HoldToFinishButton(activityMode: route.activityMode) { showFinishConfirm = true }
                .frame(width: 140)
                .accessibilityIdentifier("session.finish")
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private func togglePet(_ pet: PetProfile) {
        let willActivate = !pet.isActiveOnWalk
        let walked = session.totalDistanceCovered
        petStore.setActive(pet.id, active: willActivate)
        if willActivate {
            petActiveSinceDistance[pet.id] = walked
            allSessionPetIds.insert(pet.id)
        } else {
            if let since = petActiveSinceDistance[pet.id] {
                petAccumulatedDistances[pet.id, default: 0] += max(0, walked - since)
            }
            petActiveSinceDistance.removeValue(forKey: pet.id)
        }
    }

    private func durationText(_ t: TimeInterval) -> String {
        let s = Int(t); let m = s / 60
        return m < 60 ? "\(m)m \(s % 60)s" : "\(m / 60)h \(m % 60)m"
    }

    // MARK: - Finishing

    private var finishSummary: String {
        var parts = [session.distanceText(session.totalDistanceCovered), session.elapsedText]
        if session.estimatedSteps > 0 { parts.append("\(session.estimatedSteps.formatted()) steps") }
        return parts.joined(separator: " · ")
    }

    /// Runs after the confirmation sheet has gone, so the summary's
    /// full-screen cover is not presented on top of a dismissing sheet.
    private func runPendingFinish() {
        guard let choice = pendingFinish else { return }
        pendingFinish = nil
        switch choice {
        case .save:
            if isGuided { finishGuided(saveRoute: false) } else { endFreeSession() }
        case .saveWithRoute:
            finishGuided(saveRoute: true)
        case .discard:
            discardSession()
        }
    }

    private func finishGuided(saveRoute: Bool) {
        if saveRoute { saveCurrentRoute() }
        let pets = finalizePetDistances()
        let prev = historyStore.sessions
        let saved = walkStore.buildAndSaveSession(
            petDistances: pets.distances,
            activePetIds: pets.activePetIds,
            isCommunityRoute: route.isCommunityRoute
        )
        let cap = session
        let dist = cap.totalDistanceCovered
        let elapsed = Int(cap.elapsedTime)
        let paused = cap.totalPausedDuration
        Task {
            await WalkLiveActivityManager.shared.end(distanceCovered: dist, elapsedSeconds: elapsed, pausedDuration: paused)
            await cap.finishWorkoutSession()
        }
        let prs = saved.map { checkNewPRs(newSession: $0, against: prev) } ?? []
        finishAndShowSummary(saved: saved, prList: prs)
    }

    private func discardSession() {
        let cap = session
        let dist = cap.totalDistanceCovered
        let elapsed = Int(cap.elapsedTime)
        let paused = cap.totalPausedDuration
        cap.discardWorkoutSession()
        cap.stop()
        cancelWaterBreakReminders()
        endSessionOnDismiss = true
        Task {
            await WalkLiveActivityManager.shared.end(distanceCovered: dist, elapsedSeconds: elapsed, pausedDuration: paused)
        }
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
            showBreakPromptAlert = session.showBreakPrompt
            showDrivingBanner = session.drivingSuspected
            // Re-adopt any pets that became active while minimized.
            for pet in petStore.activePets where petActiveSinceDistance[pet.id] == nil {
                petActiveSinceDistance[pet.id] = session.totalDistanceCovered
            }
            return
        }
        // Free sessions are started in the else-branch task; guided sessions start here.
        guard isGuided else { return }

        walkStore.markStarted()
        // Quiet delivery only — the real prompt is Settings' job now. Skipped under
        // -WKTUITest for the same reason as at launch: a granted (even provisional)
        // status lets session banners render in the simulator, and a banner wakes
        // the smoke tests' interruption monitor mid-tap (Xcode Cloud, 2026-09-09).
        if !isWKTUITestMode {
            await NotificationService.shared.requestQuietDeliveryIfNeverAsked()
        }
        for pet in petStore.activePets {
            petActiveSinceDistance[pet.id] = 0
            allSessionPetIds.insert(pet.id)
        }
        WalkAudioCueService.shared.reset()
        session.start()
        session.onCheckpointReached = checkpointsEnabled ? { [self] lbl in handleCheckpoint(lbl) } : nil
        await WalkLiveActivityManager.shared.start(
            routeName: route.name,
            totalDistanceMeters: route.totalDistance,
            activityMode: route.activityMode.rawValue,
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

    private func endFreeSession() {
        let pets = finalizePetDistances()
        let prev = historyStore.sessions
        let saved = walkStore.buildAndSaveSession(
            petDistances: pets.distances,
            activePetIds: pets.activePetIds,
            isCommunityRoute: false
        )
        let cap = session
        let dist = cap.totalDistanceCovered
        let elapsed = Int(cap.elapsedTime)
        let paused = cap.totalPausedDuration
        Task {
            await WalkLiveActivityManager.shared.end(distanceCovered: dist, elapsedSeconds: elapsed, pausedDuration: paused)
        }
        let prs = saved.map { checkNewPRs(newSession: $0, against: prev) } ?? []
        finishAndShowSummary(saved: saved, prList: prs)
    }

    @discardableResult
    private func finalizePetDistances() -> (activePetIds: [UUID], distances: [UUID: Double]) {
        let currentDist = session.totalDistanceCovered
        for (petId, sinceDistance) in petActiveSinceDistance {
            petAccumulatedDistances[petId, default: 0] += max(0, currentDist - sinceDistance)
        }
        petActiveSinceDistance.removeAll()
        return (Array(petAccumulatedDistances.keys), petAccumulatedDistances)
    }

    private func handleWalkComplete() {
        let pets = finalizePetDistances()
        var s = session.completedSession
        let cap = session
        s.activePetIds = pets.activePetIds
        s.petDistances = pets.distances
        s.isCommunityRoute = route.isCommunityRoute
        let previousSessions = historyStore.sessions
        let prs = checkNewPRs(newSession: s, against: previousSessions)
        if !prs.isEmpty {
            WalkAudioCueService.shared.announce(
                "Personal record! New \(prs.map(\.title).joined(separator: " and "))!")
        }
        historyStore.add(s)
        BackgroundTaskManager.shared.scheduleCloudKitSync()
        Task {
            await WalkLiveActivityManager.shared.end(
                distanceCovered: s.totalDistance,
                elapsedSeconds: Int(s.elapsedTime),
                pausedDuration: cap.totalPausedDuration
            )
            await cap.finishWorkoutSession()
        }
        scheduleHydrationNudge(distanceMeters: s.totalDistance)
        finishAndShowSummary(saved: s, prList: prs, stopSession: false)
    }

    private func finishAndShowSummary(
        saved: WalkSession?,
        prList: [PRType],
        stopSession: Bool = true
    ) {
        // Capture split data before stop() clears live session state.
        summarySplits = session.splitTimes
        if stopSession { session.stop() }
        summaryPRs = prList
        completedPetNames = petNamesFor(ids: Array(allSessionPetIds))
        let walkPets = petStore.pets.filter { allSessionPetIds.contains($0.id) }
        petCompletions = walkPets.map { pet in
            let todaySteps = petStore.todaySteps(for: pet, in: historyStore.sessions)
            return PetCompletion(pet: pet, progress: min(1.0, Double(todaySteps) / Double(max(1, pet.goalSteps))))
        }
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

    private func petNamesFor(ids: [UUID]) -> [String] {
        ids.compactMap { id in petStore.pets.first { $0.id == id }?.name }
    }

    private func saveCurrentRoute() {
        routeStore.save(CustomRoute(
            id: UUID(),
            name: route.name,
            waypoints: route.waypoints.map { WaypointCoord($0) },
            totalDistance: route.totalDistance,
            isLoop: route.isLoop,
            createdAt: Date(),
            activityMode: route.activityMode
        ))
    }

    private func composeOwnerUpdate(for pet: PetProfile) {
        guard let phone = pet.ownerPhone, MFMessageComposeViewController.canSendText() else { return }
        let dist = MKDistanceFormatter.abbreviated.string(fromDistance: session.totalDistanceCovered)
        let petDist = MKDistanceFormatter.abbreviated.string(fromDistance: petAccumulatedDistances[pet.id] ?? 0)
        let ownerFirst = pet.ownerName?.components(separatedBy: " ").first ?? "there"
        ownerUpdateBody = "Hi \(ownerFirst)! Currently \(route.activityMode.gerund) with \(pet.name) 🐾\n\n📏 \(petDist) so far (total: \(dist))\n\nSent from Wockett"
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
            ? "Great \(String(format: "%.1f", distKm))km \(route.activityMode.noun) — drink at least 500ml of water to recover well."
            : "Good \(route.activityMode.noun) — remember to drink some water to keep your energy up."
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
        HStack(spacing: 12) {
            Image(wkt: .heat)
                .wktIcon(.row, tint: .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Heat Advisory")
                    .font(.caption.bold()).foregroundColor(.earthCream)
                Text("Hot pavement can burn paws. Keep pets hydrated.")
                    .font(.caption2).foregroundColor(.earthMuted)
            }
            Spacer()
            Button { onEnableWaterBreaks() } label: {
                Label {
                    Text("Every \(intervalMinutes) min")
                } icon: {
                    Image(wkt: .hydration)
                        .wktIcon(.inline, tint: .white, filled: true, onFill: true)
                }
                .font(.caption.bold())
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.accentInfoFill.opacity(0.85))
                .foregroundColor(.white).cornerRadius(8)
            }
            Button { onDismiss() } label: {
                Image(wkt: .dismiss)
                    .wktIcon(.inline, tint: .earthMuted)
            }
            .accessibilityLabel("Dismiss heat advisory")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }
}
