import SwiftUI
import MapKit
import CoreLocation
import UserNotifications
import UIKit

// MARK: - Walk Navigation View

struct WalkNavigationView: View {
    let route: NavigableRoute
    @ObservedObject var historyStore: WalkHistoryStore
    @EnvironmentObject var petStore: PetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(ActiveWalkStore.self) private var walkStore

    private var session: NavigationSessionManager { walkStore.session! }
    @State private var endSessionOnDismiss = false
    @StateObject private var localRouteStore = CustomRouteStore()
    @State private var showComplete            = false
    @State private var showStopAlert           = false
    @State private var waterBreakEnabled       = false
    @State private var checkpointsEnabled      = false
    @State private var scheduledBreakCount     = 0
    @State private var showHeatBanner          = false
    @State private var walkWeather: RouteWeather? = nil
    @State private var petCompletions: [PetCompletion] = []
    @State private var completedSession: WalkSession?
    @State private var completedPetNames: [String] = []
    @State private var completedPRs: [PRType] = []
    @State private var computedLegs: [MKRoute] = []
    @State private var petActiveSinceDistance: [UUID: Double] = [:]
    @State private var petAccumulatedDistances: [UUID: Double] = [:]
    @State private var allWalkPetIds: Set<UUID> = []
    @State private var walkStartDate: Date = Date()
    @State private var showBreakPromptAlert = false
    @State private var showDrivingBanner = false

    var body: some View {
        mapContent
            .toolbar(.hidden, for: .navigationBar)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .task { await startWalk() }
            .onDisappear {
                if endSessionOnDismiss { walkStore.endSession() }
            }
            .onChange(of: checkpointsEnabled) { _, enabled in handleCheckpointToggle(enabled) }
            .onChange(of: session.isCompleted) { _, completed in
                guard completed else { return }
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
                        paceSecsPerKm: pace
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
                        paceSecsPerKm: pace
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
            .alert("Still walking?", isPresented: $showBreakPromptAlert) {
                Button("End Walk") {
                    session.dismissBreakPrompt()
                    let dist = session.totalDistanceCovered
                    let elapsed = Int(session.elapsedTime)
                    let pets = finalizePetDistances()
                    walkStore.buildAndSaveSession(petDistances: pets.distances, activePetIds: pets.activePetIds, isCommunityRoute: route.isCommunityRoute)
                    session.stop()
                    cancelWaterBreakReminders()
                    endSessionOnDismiss = true
                    Task { await WalkLiveActivityManager.shared.end(distanceCovered: dist, elapsedSeconds: elapsed) }
                    dismiss()
                }
                Button("Keep Tracking", role: .cancel) {
                    session.dismissBreakPrompt()
                }
            } message: {
                Text("You haven't moved in a few minutes. End the walk or keep tracking?")
            }
            .onChange(of: waterBreakEnabled) { _, enabled in
                guard enabled else { return }
                Task { await scheduleWaterBreakReminders() }
            }
            .alert("End Walk?", isPresented: $showStopAlert) {
                Button("Save Route & End Walk") {
                    saveCurrentRoute()
                    let dist = session.totalDistanceCovered
                    let elapsed = Int(session.elapsedTime)
                    let pets = finalizePetDistances()
                    walkStore.buildAndSaveSession(petDistances: pets.distances, activePetIds: pets.activePetIds, isCommunityRoute: route.isCommunityRoute)
                    session.stop()
                    cancelWaterBreakReminders()
                    endSessionOnDismiss = true
                    Task { await WalkLiveActivityManager.shared.end(distanceCovered: dist, elapsedSeconds: elapsed) }
                    dismiss()
                }
                Button("End Walk") {
                    let dist = session.totalDistanceCovered
                    let elapsed = Int(session.elapsedTime)
                    let pets = finalizePetDistances()
                    walkStore.buildAndSaveSession(petDistances: pets.distances, activePetIds: pets.activePetIds, isCommunityRoute: route.isCommunityRoute)
                    session.stop()
                    cancelWaterBreakReminders()
                    endSessionOnDismiss = true
                    Task { await WalkLiveActivityManager.shared.end(distanceCovered: dist, elapsedSeconds: elapsed) }
                    dismiss()
                }
                Button("Discard Walk", role: .destructive) {
                    let dist = session.totalDistanceCovered
                    let elapsed = Int(session.elapsedTime)
                    session.stop()
                    cancelWaterBreakReminders()
                    endSessionOnDismiss = true
                    Task { await WalkLiveActivityManager.shared.end(distanceCovered: dist, elapsedSeconds: elapsed) }
                    dismiss()
                }
                Button("Keep Walking", role: .cancel) {}
            } message: {
                Text("Save this walk to your history? You can also save the route to My Routes so you can walk it again.")
            }
    }

    @ViewBuilder private var mapContent: some View {
        ZStack(alignment: .bottom) {
            NavigationMapView(route: route, computedLegs: computedLegs, currentWaypointIndex: session.currentWaypointIndex, checkpointsEnabled: checkpointsEnabled, distanceCoveredMeters: session.totalDistanceCovered)
                .ignoresSafeArea()
            hudPanel
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.earthCream)
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .padding(.top, 60)
            .padding(.leading, 16)
        }
        .fullScreenCover(isPresented: $showComplete, onDismiss: {
            cancelWaterBreakReminders()
            endSessionOnDismiss = true
            dismiss()
        }) {
            if let s = completedSession {
                WalkCompleteView(
                    session: s,
                    activePetNames: completedPetNames,
                    petCompletions: petCompletions,
                    splits: session.splitTimes,
                    newPRs: completedPRs,
                    onDismiss: { showComplete = false },
                    onExcludeFromRouteStats: s.customRouteId != nil ? {
                        historyStore.updateCountsTowardRouteStats(id: s.id, counts: false)
                    } : nil,
                    historyStore: historyStore
                )
            }
        }
    }

    private func handleCheckpointToggle(_ enabled: Bool) {
        session.onCheckpointReached = enabled ? { [self] lbl in self.handleCheckpoint(lbl) } : nil
    }

    private func startWalk() async {
        guard !walkStore.isStarted else {
            // Re-presenting after navigating away — recompute display data without restarting
            computedLegs = await computeWalkingLegs()
            if let firstWaypoint = route.waypoints.first {
                walkWeather = await RouteWeatherService.shared.fetchWeather(for: firstWaypoint)
            }
            session.onCheckpointReached = checkpointsEnabled ? { [self] lbl in self.handleCheckpoint(lbl) } : nil
            // Resync flags that onChange only fires on transitions — if these were set before
            // the user minimized, they must be re-applied when the map is reopened.
            showBreakPromptAlert = session.showBreakPrompt
            showDrivingBanner = session.drivingSuspected
            return
        }
        walkStore.markStarted()
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            try? await center.requestAuthorization(options: [.alert, .sound])
        }
        walkStartDate = Date()
        for pet in petStore.activePets {
            petActiveSinceDistance[pet.id] = 0
            allWalkPetIds.insert(pet.id)
        }
        WalkAudioCueService.shared.reset()
        session.start()
        session.onCheckpointReached = checkpointsEnabled ? { [self] lbl in self.handleCheckpoint(lbl) } : nil
        WalkLiveActivityManager.shared.start(
            routeName: route.name,
            totalDistanceMeters: route.totalDistance,
            activityMode: route.activityMode.rawValue
        )
        computedLegs = await computeWalkingLegs()
        if let firstWaypoint = route.waypoints.first {
            walkWeather = await RouteWeatherService.shared.fetchWeather(for: firstWaypoint)
        }
        if let w = walkWeather, w.temperatureCelsius > 27, !petStore.activePets.isEmpty {
            showHeatBanner = true
        }
    }

    private func finalizePetDistances() -> (activePetIds: [UUID], distances: [UUID: Double]) {
        let finalWalked = route.totalDistance - session.remainingDistance
        for (petId, sinceDistance) in petActiveSinceDistance {
            petAccumulatedDistances[petId, default: 0] += max(0, finalWalked - sinceDistance)
        }
        petActiveSinceDistance.removeAll()
        return (Array(petAccumulatedDistances.keys), petAccumulatedDistances)
    }

    private func handleWalkComplete() {
        let pets = finalizePetDistances()

        var s = session.completedSession
        let capturedSession = session
        s.activePetIds = pets.activePetIds
        s.petDistances = pets.distances
        s.isCommunityRoute = route.isCommunityRoute
        let previousSessions = historyStore.sessions
        completedPRs = checkNewPRs(newSession: s, against: previousSessions)
        if !completedPRs.isEmpty {
            let prText = completedPRs.map(\.title).joined(separator: " and ")
            WalkAudioCueService.shared.announce("Personal record! New \(prText)!")
        }
        historyStore.add(s)
        BackgroundTaskManager.shared.scheduleCloudKitSync()
        Task {
            await WalkLiveActivityManager.shared.end(
                distanceCovered: s.totalDistance,
                elapsedSeconds: Int(s.elapsedTime)
            )
            await capturedSession.finishWorkoutSession()
        }
        completedSession = s
        completedPetNames = petNamesFor(ids: Array(allWalkPetIds))
        let walkPets = petStore.pets.filter { allWalkPetIds.contains($0.id) }
        petCompletions = walkPets.map { pet in
            let todaySteps = petStore.todaySteps(for: pet, in: historyStore.sessions)
            return PetCompletion(pet: pet, progress: min(1.0, Double(todaySteps) / Double(max(1, pet.goalSteps))))
        }
        scheduleHydrationNudge(distanceMeters: s.totalDistance)
        showComplete = true
    }

    private func scheduleHydrationNudge(distanceMeters: Double) {
        guard UserDefaults.standard.object(forKey: "notif_hydration") as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = NotificationCategory.hydration
        content.title = "Time to rehydrate! 💧"
        let distKm = distanceMeters / 1000
        if distKm >= 5 {
            content.body = "Great \(String(format: "%.1f", distKm))km walk — drink at least 500ml of water to recover well."
        } else {
            content.body = "Good walk — remember to drink some water to keep your energy up."
        }
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 300, repeats: false)
        let req = UNNotificationRequest(identifier: "hydration-\(UUID().uuidString)", content: content, trigger: trigger)
        Task { try? await UNUserNotificationCenter.current().add(req) }
    }

    private func handlePetCountChange(_ count: Int) {
        if count == 0 {
            showHeatBanner = false
            if waterBreakEnabled { cancelWaterBreakReminders(); waterBreakEnabled = false }
        } else if let w = walkWeather, w.temperatureCelsius > 27 {
            showHeatBanner = true
        }
    }

    private func handleCheckpoint(_ label: String) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        if checkpointsEnabled {
            let content = UNMutableNotificationContent()
            content.title = "Checkpoint \(label) 🎯"
            content.body = "Keep it up!"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
            let req = UNNotificationRequest(identifier: "checkpoint-\(label)", content: content, trigger: trigger)
            Task { try? await UNUserNotificationCenter.current().add(req) }
        }
    }

    private var hudPanel: some View {
        VStack(spacing: 0) {
            if showDrivingBanner {
                DrivingSuspectedBanner(
                    onStillWalking: {
                        session.clearDrivingSuspicion()
                        showDrivingBanner = false
                    },
                    onEndWalk: {
                        showDrivingBanner = false
                        let capturedSession = session
                        capturedSession.stop()
                        Task { await WalkLiveActivityManager.shared.end(
                            distanceCovered: capturedSession.totalDistanceCovered,
                            elapsedSeconds:  Int(capturedSession.elapsedTime)
                        )}
                        handleWalkComplete()
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
                    onEnableWaterBreaks: {
                        waterBreakEnabled = true
                        showHeatBanner = false
                    },
                    onDismiss: { showHeatBanner = false }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color.earthMuted.opacity(0.25))
                    .transition(.opacity)
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: route.activityMode.icon)
                            .font(.subheadline).foregroundColor(.earthGreen)
                        Text(route.name)
                            .font(.headline).foregroundColor(.earthCream).lineLimit(1)
                    }
                    Text(session.progressText)
                        .font(.subheadline).foregroundColor(.earthGreen)
                }
                Spacer()
                if !petStore.pets.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(petStore.pets) { pet in
                            Button {
                                let willActivate = !pet.isActiveOnWalk
                                let walked = route.totalDistance - session.remainingDistance
                                petStore.setActive(pet.id, active: willActivate)
                                if willActivate {
                                    petActiveSinceDistance[pet.id] = walked
                                    allWalkPetIds.insert(pet.id)
                                } else {
                                    if let since = petActiveSinceDistance[pet.id] {
                                        petAccumulatedDistances[pet.id, default: 0] += max(0, walked - since)
                                    }
                                    petActiveSinceDistance.removeValue(forKey: pet.id)
                                }
                            } label: {
                                Text(pet.displayEmoji)
                                    .font(.title2)
                                    .opacity(pet.isActiveOnWalk ? 1.0 : 0.3)
                                    .scaleEffect(pet.isActiveOnWalk ? 1.0 : 0.85)
                                    .animation(.spring(duration: 0.2), value: pet.isActiveOnWalk)
                            }
                        }
                    }
                    .padding(.trailing, 6)
                }
                Button {
                    WalkAudioCueService.shared.isEnabled.toggle()
                } label: {
                    Image(systemName: WalkAudioCueService.shared.isEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                        .font(.title2)
                        .foregroundColor(WalkAudioCueService.shared.isEnabled ? .earthGreen : .earthMuted)
                }
                .padding(.trailing, 10)
                Button {
                    waterBreakEnabled.toggle()
                    if !waterBreakEnabled { cancelWaterBreakReminders() }
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: waterBreakEnabled ? "drop.fill" : "drop")
                            .font(.title2)
                            .foregroundColor(waterBreakEnabled ? Color(red: 0.28, green: 0.49, blue: 0.84) : .earthMuted)
                        if waterBreakEnabled {
                            Text("/ \(waterBreakIntervalMinutes)m")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Color(red: 0.28, green: 0.49, blue: 0.84))
                        }
                    }
                    .animation(.spring(duration: 0.2), value: waterBreakEnabled)
                }
                .padding(.trailing, 10)
                Button {
                    checkpointsEnabled.toggle()
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: checkpointsEnabled ? "flag.fill" : "flag")
                            .font(.title2)
                            .foregroundColor(checkpointsEnabled ? Color(red: 0.35, green: 0.22, blue: 0.72) : .earthMuted)
                        if checkpointsEnabled {
                            Text(route.isCustomRoute ? "WP" : "20%")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.72))
                        }
                    }
                    .animation(.spring(duration: 0.2), value: checkpointsEnabled)
                }
                .padding(.trailing, 10)
                Button {
                    if session.isPaused { session.resume() } else { session.pause() }
                } label: {
                    Image(systemName: session.isPaused ? "play.circle.fill" : "pause.circle")
                        .font(.title)
                        .foregroundColor(session.isPaused ? .earthGreen : .earthMuted)
                }
                .padding(.trailing, 10)
                Button { showStopAlert = true } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title)
                        .foregroundColor(.red.opacity(0.85))
                }
            }
            .padding(.horizontal, 20).padding(.top, 20)

            if session.isPaused {
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle.fill")
                        .foregroundColor(.earthOrange)
                    Text("Walk Paused")
                        .font(.caption.bold())
                        .foregroundColor(.earthOrange)
                    Spacer()
                    Button {
                        session.resume()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.earthGreen.opacity(0.9))
                            .foregroundColor(.white).cornerRadius(8)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.earthOrange.opacity(0.1))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.earthMuted.opacity(0.25))
                .padding(.top, session.isPaused ? 0 : 14)

            HStack(spacing: 0) {
                hudStat(value: distText(session.distanceToNextWaypoint), label: "to next",  icon: "location.fill")
                Rectangle().frame(width: 0.5, height: 36).foregroundColor(Color.earthMuted.opacity(0.25))
                hudStat(value: distText(session.remainingDistance),      label: "remaining", icon: "flag.fill")
                Rectangle().frame(width: 0.5, height: 36).foregroundColor(Color.earthMuted.opacity(0.25))
                hudStat(value: timeText(session.elapsedTime),            label: "elapsed",  icon: "clock.fill")
                Rectangle().frame(width: 0.5, height: 36).foregroundColor(Color.earthMuted.opacity(0.25))
                hudStat(value: session.paceText,                         label: "pace",     icon: "speedometer")
            }
            .padding(.vertical, 14)

            if session.estimatedSteps > 0 {
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color.earthMuted.opacity(0.25))
                HStack(spacing: 0) {
                    VStack(spacing: 5) {
                        Image(systemName: "figure.walk").font(.caption).foregroundColor(.earthGreen)
                        Text(session.estimatedSteps.formatted()).font(.subheadline.bold()).foregroundColor(.earthCream)
                        Text("steps").font(.caption2).foregroundColor(.earthMuted)
                        if let cad = session.cadence, cad > 0 {
                            Text("\(Int(cad))/min")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.earthGreen)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    if let eta = session.estimatedSecondsRemaining {
                        Rectangle().frame(width: 0.5, height: 36).foregroundColor(Color.earthMuted.opacity(0.25))
                        hudStat(value: etaText(eta), label: "est. left", icon: "timer")
                    }
                }
                .padding(.vertical, 14)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showDrivingBanner)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showHeatBanner)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: session.isPaused)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: session.estimatedSteps > 0)
        .background(.ultraThinMaterial)
    }

    private func hudStat(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.caption).foregroundColor(.earthGreen)
            Text(value).font(.subheadline.bold()).foregroundColor(.earthCream)
            Text(label).font(.caption2).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private func petNamesFor(ids: [UUID]) -> [String] {
        ids.compactMap { id in petStore.pets.first { $0.id == id }?.name }
    }

    private func distText(_ m: Double) -> String {
        MKDistanceFormatter.abbreviated.string(fromDistance: max(0, m))
    }

    private func timeText(_ t: TimeInterval) -> String {
        let s = Int(t); let m = s / 60
        return m < 60 ? "\(m)m \(s % 60)s" : "\(m / 60)h \(m % 60)m"
    }

    private func etaText(_ seconds: Double) -> String {
        let s = Int(seconds); let m = s / 60
        return m < 60 ? "\(m)m \(s % 60)s" : "\(m / 60)h \(m % 60)m"
    }

    private func saveCurrentRoute() {
        let customRoute = CustomRoute(
            id: UUID(),
            name: route.name,
            waypoints: route.waypoints.map { WaypointCoord($0) },
            totalDistance: route.totalDistance,
            isLoop: route.isLoop,
            createdAt: Date()
        )
        localRouteStore.save(customRoute)
    }

    private var waterBreakIntervalMinutes: Int {
        let temp = walkWeather?.temperatureCelsius ?? 20
        if temp > 32 { return 10 }
        if temp > 27 { return 15 }
        return 20
    }

    private func scheduleWaterBreakReminders() async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        } else if status != .authorized { return }
        let intervalSecs = Double(waterBreakIntervalMinutes) * 60
        let estimatedDurationMins = route.totalDistance / 1.4 / 60
        let count = min(12, max(1, Int(ceil(estimatedDurationMins / Double(waterBreakIntervalMinutes)))))
        scheduledBreakCount = count
        for i in 1...count {
            let content = UNMutableNotificationContent()
            content.title = "Water break! 💧"
            content.body = petStore.activePets.isEmpty
                ? "Time for a water break."
                : "Time to hydrate — your \(petStore.activePets.count == 1 ? "pup" : "pups") need water too."
            content.sound = .default
            content.categoryIdentifier = NotificationCategory.waterBreak
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Double(i) * intervalSecs, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "waterBreak-\(i)", content: content, trigger: trigger))
        }
    }

    private func cancelWaterBreakReminders() {
        let count = max(scheduledBreakCount, 12)
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: (1...count).map { "waterBreak-\($0)" }
        )
        scheduledBreakCount = 0
    }

    private func computeWalkingLegs() async -> [MKRoute] {
        let wps = route.waypoints
        guard wps.count >= 2 else { return [] }
        var legs: [MKRoute] = []
        let legCount = route.isLoop ? wps.count : wps.count - 1
        for i in 0..<legCount {
            let from = wps[i]
            let to = wps[(i + 1) % wps.count]
            let req = MKDirections.Request()
            req.source        = MKMapItem(location: CLLocation(latitude: from.latitude, longitude: from.longitude), address: nil)
            req.destination   = MKMapItem(location: CLLocation(latitude: to.latitude, longitude: to.longitude), address: nil)
            req.transportType = route.activityMode.transportType
            if let r = try? await MKDirections(request: req).calculate().routes.first {
                legs.append(r)
            }
        }
        return legs
    }
}

// MARK: - Heat Advisory Banner

private struct DrivingSuspectedBanner: View {
    let onStillWalking: () -> Void
    let onEndWalk: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "car.fill")
                .font(.title3).foregroundColor(.red.opacity(0.85))
            VStack(alignment: .leading, spacing: 2) {
                Text("This looks faster than a walk")
                    .font(.caption.bold()).foregroundColor(.earthCream)
                Text("Still walking, or are you driving?")
                    .font(.caption2).foregroundColor(.earthMuted)
            }
            Spacer()
            Button { onStillWalking() } label: {
                Text("Still walking")
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.earthGreen.opacity(0.85))
                    .foregroundColor(.white).cornerRadius(8)
            }
            Button { onEndWalk() } label: {
                Text("End walk")
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.red.opacity(0.75))
                    .foregroundColor(.white).cornerRadius(8)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.red.opacity(0.1))
    }
}

private struct HeatAdvisoryBanner: View {
    let intervalMinutes: Int
    let onEnableWaterBreaks: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "thermometer.high")
                .font(.title3).foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Heat Advisory")
                    .font(.caption.bold()).foregroundColor(.earthCream)
                Text("Hot pavement can burn paws. Keep pets hydrated.")
                    .font(.caption2).foregroundColor(.earthMuted)
            }
            Spacer()
            Button { onEnableWaterBreaks() } label: {
                Label("Every \(intervalMinutes) min", systemImage: "drop.fill")
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(red: 0.28, green: 0.49, blue: 0.84).opacity(0.85))
                    .foregroundColor(.white).cornerRadius(8)
            }
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.caption).foregroundColor(.earthMuted)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }
}
