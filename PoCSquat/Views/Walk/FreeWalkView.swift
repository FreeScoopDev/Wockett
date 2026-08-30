import SwiftUI
import Combine
import MapKit
import CoreLocation
import MessageUI

// MARK: - POI Support

enum WalkPOIFilter: String, CaseIterable {
    case cafe, park, food, restroom, pharmacy

    var emoji: String {
        switch self {
        case .cafe:     return "☕️"
        case .park:     return "🌳"
        case .food:     return "🍽️"
        case .restroom: return "🚻"
        case .pharmacy: return "💊"
        }
    }

    var label: String {
        switch self {
        case .cafe:     return "Café"
        case .park:     return "Park"
        case .food:     return "Food"
        case .restroom: return "Restroom"
        case .pharmacy: return "Pharmacy"
        }
    }

    var mkCategories: [MKPointOfInterestCategory] {
        switch self {
        case .cafe:     return [.cafe]
        case .park:     return [.park, .nationalPark]
        case .food:     return [.restaurant, .foodMarket, .bakery]
        case .restroom: return [.restroom]
        case .pharmacy: return [.pharmacy]
        }
    }

    var color: Color {
        switch self {
        case .cafe:     return Color(red: 0.52, green: 0.33, blue: 0.18)
        case .park:     return .earthGreen
        case .food:     return .earthOrange
        case .restroom: return Color(red: 0.28, green: 0.49, blue: 0.84)
        case .pharmacy: return Color(red: 0.72, green: 0.22, blue: 0.28)
        }
    }
}

struct NearbyPOI: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let name: String
    let category: WalkPOIFilter
    let mapItem: MKMapItem
}

@MainActor
final class POIOverlayManager: ObservableObject {
    @Published var activeCategories: Set<WalkPOIFilter> = []
    @Published var pois: [NearbyPOI] = []
    @Published var selectedPOI: NearbyPOI? = nil

    private var lastFetchLocation: CLLocationCoordinate2D?

    func enable(_ category: WalkPOIFilter, near coordinate: CLLocationCoordinate2D?) {
        guard !activeCategories.contains(category) else { return }
        activeCategories.insert(category)
        guard let coord = coordinate else { return }
        if lastFetchLocation == nil { lastFetchLocation = coord }
        fetchCategory(category, near: coord)
    }

    func disable(_ category: WalkPOIFilter) {
        activeCategories.remove(category)
        pois.removeAll { $0.category == category }
        if selectedPOI?.category == category { selectedPOI = nil }
    }

    func refreshIfNeeded(near coordinate: CLLocationCoordinate2D) {
        guard !activeCategories.isEmpty else { return }
        if let last = lastFetchLocation {
            let dist = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
            guard dist >= 300 else { return }
        }
        lastFetchLocation = coordinate
        for category in activeCategories { fetchCategory(category, near: coordinate) }
    }

    private func fetchCategory(_ category: WalkPOIFilter, near coordinate: CLLocationCoordinate2D) {
        Task {
            let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800)
            let request = MKLocalSearch.Request()
            request.region = region
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: category.mkCategories)
            request.resultTypes = .pointOfInterest
            let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
            let newPOIs = items.prefix(8).compactMap { item -> NearbyPOI? in
                guard let name = item.name else { return nil }
                return NearbyPOI(coordinate: item.location.coordinate, name: name,
                                 category: category, mapItem: item)
            }
            pois.removeAll { $0.category == category }
            pois.append(contentsOf: newPOIs)
        }
    }
}

// MARK: - Free Walk View

struct FreeWalkView: View {
    @EnvironmentObject var petStore: PetStore
    @ObservedObject var historyStore: WalkHistoryStore
    @ObservedObject var routeStore: CustomRouteStore
    @Environment(\.dismiss) private var dismiss
    @Environment(ActiveWalkStore.self) private var walkStore

    var activityMode: ActivityMode = .walking

    @State private var showSummary = false
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var petActiveSinceDistance: [UUID: Double] = [:]
    @State private var petDistances: [UUID: Double] = [:]
    @StateObject private var poiManager = POIOverlayManager()
    @State private var showOwnerUpdateSheet   = false
    @State private var ownerUpdateRecipient: String? = nil
    @State private var ownerUpdateBody        = ""
    @State private var ownerUpdatePickerPets: [PetProfile] = []
    @State private var endSessionOnDismiss    = false
    @State private var hasAttemptedStart      = false
    @State private var showBreakPromptAlert   = false

    private var isCycling: Bool { activityMode == .cycling }
    private var session: NavigationSessionManager { walkStore.session! }

    private var freeWalkRouteName: String {
        activityMode == .cycling ? "Free Ride" : activityMode == .running ? "Free Run" : "Free Walk"
    }

    private func elapsedText(_ t: TimeInterval) -> String {
        let s = Int(t)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private func distanceText(_ meters: Double) -> String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: max(meters, 0))
    }

    var body: some View {
        if walkStore.session != nil {
            ZStack(alignment: .top) {
                Map(position: $position, bounds: MapCameraBounds(minimumDistance: 100, maximumDistance: 800)) {
                    if session.trackPoints.count > 1 {
                        MapPolyline(coordinates: session.trackPoints)
                            .stroke(isCycling ? Color(red: 0.13, green: 0.57, blue: 0.64) : Color.earthGreen, lineWidth: 5)
                    }
                    UserAnnotation()
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
                                    Text(poi.category.emoji)
                                        .font(.system(size: 17))
                                }
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: poiManager.selectedPOI?.id == poi.id ? 2.5 : 0)
                                )
                            }
                        }
                    }
                }
                .mapStyle(.standard)
                .ignoresSafeArea()

                VStack {
                    // Stats HUD
                    HStack(spacing: 0) {
                        hudStat(value: distanceText(session.totalDistanceCovered), label: "Distance")
                        Divider().frame(height: 36)
                        hudStat(value: elapsedText(session.elapsedTime), label: "Time")
                        Divider().frame(height: 36)
                        hudStepStat(
                            steps: isCycling ? session.estimatedSteps : session.liveSteps,
                            cadence: isCycling ? nil : session.cadence,
                            label: isCycling ? "Rotations" : "Steps"
                        )
                    }
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial)
                    .cornerRadius(18)
                    .padding(.horizontal, 20)
                    .padding(.top, 56)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(WalkPOIFilter.allCases, id: \.rawValue) { cat in
                                Button {
                                    if poiManager.activeCategories.contains(cat) {
                                        poiManager.disable(cat)
                                    } else {
                                        poiManager.enable(cat, near: session.trackPoints.last)
                                    }
                                } label: {
                                    poiChip(cat)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.vertical, 6)

                    if !petStore.pets.isEmpty {
                        HStack(spacing: 12) {
                            ForEach(petStore.pets) { pet in
                                Button {
                                    let willActivate = !pet.isActiveOnWalk
                                    let currentDist = session.totalDistanceCovered
                                    petStore.setActive(pet.id, active: willActivate)
                                    if willActivate {
                                        petActiveSinceDistance[pet.id] = currentDist
                                    } else {
                                        if let since = petActiveSinceDistance[pet.id] {
                                            petDistances[pet.id, default: 0] += max(0, currentDist - since)
                                        }
                                        petActiveSinceDistance.removeValue(forKey: pet.id)
                                    }
                                } label: {
                                    VStack(spacing: 2) {
                                        Text(pet.displayEmoji)
                                            .font(.title2)
                                            .opacity(pet.isActiveOnWalk ? 1.0 : 0.35)
                                            .scaleEffect(pet.isActiveOnWalk ? 1.0 : 0.85)
                                        Text(pet.name)
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundColor(pet.isActiveOnWalk ? .primary : .secondary)
                                    }
                                    .animation(.spring(duration: 0.2), value: pet.isActiveOnWalk)
                                }
                            }
                        }
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .cornerRadius(18)
                        .padding(.horizontal, 20)

                        let activePetsWithOwner = petStore.activePets.filter { $0.ownerPhone != nil }
                        if !activePetsWithOwner.isEmpty && MFMessageComposeViewController.canSendText() {
                            Button {
                                if activePetsWithOwner.count == 1 {
                                    composeOwnerUpdate(for: activePetsWithOwner[0])
                                } else {
                                    ownerUpdatePickerPets = activePetsWithOwner
                                }
                            } label: {
                                Label("Update Owner\(activePetsWithOwner.count > 1 ? "s" : "")", systemImage: "message.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(Color.earthGreen.opacity(0.85))
                                    .cornerRadius(14)
                            }
                            .padding(.horizontal, 20)
                        }
                    }

                    Spacer()

                    if let poi = poiManager.selectedPOI {
                        HStack(spacing: 12) {
                            Text(poi.category.emoji).font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(poi.name)
                                    .font(.subheadline.bold())
                                    .foregroundColor(.earthCream)
                                    .lineLimit(1)
                                if let dist = distanceToUser(poi.coordinate) {
                                    Text(dist).font(.caption).foregroundColor(.earthMuted)
                                }
                            }
                            Spacer()
                            Button {
                                poi.mapItem.openInMaps(launchOptions: [
                                    MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
                                ])
                            } label: {
                                Image(systemName: "map.fill")
                                    .padding(9)
                                    .background(Color.earthGreen.opacity(0.9))
                                    .foregroundColor(.white)
                                    .clipShape(Circle())
                            }
                            Button {
                                withAnimation(.spring(response: 0.3)) { poiManager.selectedPOI = nil }
                            } label: {
                                Image(systemName: "xmark")
                                    .padding(9)
                                    .background(Color.earthCard)
                                    .foregroundColor(.earthMuted)
                                    .clipShape(Circle())
                            }
                        }
                        .padding(14)
                        .background(.ultraThinMaterial)
                        .cornerRadius(16)
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    Button {
                        if session.isPaused { session.resume() } else { session.pause() }
                    } label: {
                        Image(systemName: session.isPaused ? "play.circle.fill" : "pause.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(session.isPaused ? .earthGreen : .white.opacity(0.85))
                            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                    }
                    .padding(.bottom, 4)

                    if session.isPaused {
                        Text("\(activityMode.sessionLabel) Paused")
                            .font(.caption.bold())
                            .foregroundColor(.earthOrange)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.bottom, 6)
                    }

                    Button {
                        flushActivePetDistances()
                        let dist = session.totalDistanceCovered
                        let elapsed = Int(session.elapsedTime)
                        let pausedDuration = session.totalPausedDuration
                        Task { await WalkLiveActivityManager.shared.end(
                            distanceCovered: dist,
                            elapsedSeconds: elapsed,
                            pausedDuration: pausedDuration
                        )}
                        session.stop()
                        endSessionOnDismiss = true
                        showSummary = true
                    } label: {
                        Label("Finish \(activityMode.sessionLabel)", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(isCycling ? Color(red: 0.13, green: 0.57, blue: 0.64) : Color.earthGreen)
                            .foregroundColor(.white)
                            .font(.headline)
                            .cornerRadius(14)
                            .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 48)
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: poiManager.selectedPOI?.id)
            }
            .onAppear {
                // Re-appearing after minimize — adopt existing session without restarting
                guard walkStore.isStarted else { return }
                for pet in petStore.activePets where petActiveSinceDistance[pet.id] == nil {
                    petActiveSinceDistance[pet.id] = session.totalDistanceCovered
                }
            }
            .onDisappear { handleDisappear() }
            .onChange(of: session.trackPoints.count) { _, _ in
                if let last = session.trackPoints.last {
                    poiManager.refreshIfNeeded(near: last)
                }
            }
            .onChange(of: Int(session.elapsedTime)) { _, elapsed in
                guard elapsed > 0, elapsed % 10 == 0 else { return }
                let dist = session.totalDistanceCovered
                let paused = session.isPaused
                let pace: Double? = dist > 50 ? Double(elapsed) / (dist / 1_000) : nil
                Task { await WalkLiveActivityManager.shared.update(
                    distanceCovered: dist,
                    elapsedSeconds: elapsed,
                    isPaused: paused,
                    paceSecsPerKm: pace,
                    pausedDuration: session.totalPausedDuration,
                    pauseTime: paused ? Date() : nil
                )}
            }
            .onChange(of: session.isPaused) { _, paused in
                let dist = session.totalDistanceCovered
                let elapsed = Int(session.elapsedTime)
                let pace: Double? = dist > 50 ? Double(elapsed) / (dist / 1_000) : nil
                Task { await WalkLiveActivityManager.shared.update(
                    distanceCovered: dist,
                    elapsedSeconds: elapsed,
                    isPaused: paused,
                    paceSecsPerKm: pace,
                    pausedDuration: session.totalPausedDuration,
                    pauseTime: paused ? Date() : nil
                )}
            }
            .onChange(of: session.showBreakPrompt) { _, show in
                if show { showBreakPromptAlert = true }
            }
            .alert("Still \(activityMode.gerund.capitalized)?", isPresented: $showBreakPromptAlert) {
                Button("End \(activityMode.sessionLabel)") {
                    session.dismissBreakPrompt()
                    flushActivePetDistances()
                    let dist = session.totalDistanceCovered
                    let elapsed = Int(session.elapsedTime)
                    let pausedDuration = session.totalPausedDuration
                    if session.autoPausedForInactivity { session.resume() }
                    Task { await WalkLiveActivityManager.shared.end(
                        distanceCovered: dist,
                        elapsedSeconds: elapsed,
                        pausedDuration: pausedDuration
                    )}
                    session.stop()
                    endSessionOnDismiss = true
                    showSummary = true
                }
                Button("Keep Tracking", role: .cancel) {
                    session.dismissBreakPrompt()
                    if session.autoPausedForInactivity { session.resume() }
                }
            } message: {
                Text("You haven't moved in a few minutes. End or keep tracking?")
            }
            .sheet(isPresented: $showSummary) {
                FreeWalkSummarySheet(
                    session: session,
                    historyStore: historyStore,
                    routeStore: routeStore,
                    petDistances: petDistances,
                    activityMode: activityMode
                ) {
                    endSessionOnDismiss = true
                    dismiss()
                }
            }
            .sheet(isPresented: $showOwnerUpdateSheet) {
                if let phone = ownerUpdateRecipient {
                    MessageComposeSheet(recipients: [phone], body: ownerUpdateBody)
                }
            }
            .confirmationDialog("Send update to owner", isPresented: .init(
                get: { ownerUpdatePickerPets.count > 1 && showOwnerUpdateSheet == false && !ownerUpdatePickerPets.isEmpty },
                set: { if !$0 { ownerUpdatePickerPets = [] } }
            ), titleVisibility: .visible) {
                ForEach(ownerUpdatePickerPets, id: \.id) { pet in
                    Button(pet.ownerName ?? pet.name) { composeOwnerUpdate(for: pet) }
                }
            }
        } else {
            Color.clear
                .task {
                    if hasAttemptedStart {
                        // We already started a walk in this view instance and it's since been
                        // cleared externally (e.g. Live Activity End Walk) — dismiss instead
                        // of silently starting a new one.
                        dismiss()
                        return
                    }
                    hasAttemptedStart = true
                    let route = NavigableRoute(
                        name: freeWalkRouteName,
                        waypoints: [],
                        lapCount: 1,
                        isLoop: false,
                        totalDistance: 0,
                        isCustomRoute: true,
                        isCommunityRoute: false,
                        activityMode: activityMode,
                        customRouteId: nil
                    )
                    guard walkStore.beginSession(route: route) != nil else { dismiss(); return }
                    walkStore.markStarted()
                    session.start()
                    for pet in petStore.activePets {
                        petActiveSinceDistance[pet.id] = 0
                    }
                    await WalkLiveActivityManager.shared.start(
                        routeName: route.name,
                        totalDistanceMeters: 0,
                        activityMode: activityMode.rawValue,
                        startDate: session.startTime
                    )
                }
        }
    }

    private func handleDisappear() {
        guard endSessionOnDismiss else { return }
        walkStore.endSession()
    }

    private func composeOwnerUpdate(for pet: PetProfile) {
        guard let phone = pet.ownerPhone, MFMessageComposeViewController.canSendText() else { return }
        let dist = MKDistanceFormatter.abbreviated.string(fromDistance: session.totalDistanceCovered)
        let petDist = MKDistanceFormatter.abbreviated.string(fromDistance: petDistances[pet.id] ?? 0)
        let ownerFirst = pet.ownerName?.components(separatedBy: " ").first ?? "there"
        ownerUpdateBody = "Hi \(ownerFirst)! Currently walking \(pet.name) 🐾\n\n📏 \(petDist) so far (total walk: \(dist))\n\nSent from Wockett"
        ownerUpdateRecipient = phone
        ownerUpdatePickerPets = []
        showOwnerUpdateSheet = true
    }

    private func flushActivePetDistances() {
        let currentDist = session.totalDistanceCovered
        for (petId, sinceDistance) in petActiveSinceDistance {
            petDistances[petId, default: 0] += max(0, currentDist - sinceDistance)
        }
        petActiveSinceDistance.removeAll()
    }

    private func hudStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    private func hudStepStat(steps: Int, cadence: Double?, label: String) -> some View {
        VStack(spacing: 2) {
            Text(steps.formatted())
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let cad = cadence, cad > 0 {
                Text("\(Int(cad))/min")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.earthGreen)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    private func poiChip(_ cat: WalkPOIFilter) -> some View {
        let active = poiManager.activeCategories.contains(cat)
        return HStack(spacing: 4) {
            Text(cat.emoji).font(.footnote)
            Text(cat.label).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(active ? cat.color : Color(UIColor.systemGray6).opacity(0.9))
        .foregroundColor(active ? Color.white : Color.secondary)
        .clipShape(Capsule())
        .animation(.spring(response: 0.25), value: active)
    }

    private func distanceToUser(_ coord: CLLocationCoordinate2D) -> String? {
        guard let last = session.trackPoints.last else { return nil }
        let dist = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
        return MKDistanceFormatter.abbreviated.string(fromDistance: dist) + " away"
    }
}

// MARK: - Free Walk Summary Sheet

struct FreeWalkSummarySheet: View {
    let session: NavigationSessionManager
    @ObservedObject var historyStore: WalkHistoryStore
    @ObservedObject var routeStore: CustomRouteStore
    @EnvironmentObject var petStore: PetStore
    @Environment(ActiveWalkStore.self) private var walkStore
    let petDistances: [UUID: Double]
    var activityMode: ActivityMode = .walking
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var savedToHistory    = false
    @State private var savedAsRoute      = false
    @State private var showRouteNameField = false
    @State private var routeName         = ""
    @State private var newPRs: [PRType]  = []
    @State private var shareItems: [Any] = []
    @State private var showShareSheet    = false
    @State private var msgRecipient: String? = nil
    @State private var msgBody           = ""
    @State private var showMsgSheet      = false

    private var walkedPets: [PetProfile] {
        petStore.pets.filter { (petDistances[$0.id] ?? 0) > 0 }
    }

    private func elapsedText(_ t: TimeInterval) -> String {
        let s = Int(t)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private func distanceText(_ meters: Double) -> String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: max(meters, 0))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 8) {
                            Text("🎉").font(.system(size: 52))
                            Text("\(activityMode.sessionLabel) Complete!")
                                .font(.title2.bold()).foregroundColor(.earthCream)
                        }
                        .padding(.top, 8)

                        HStack(spacing: 12) {
                            statTile(value: distanceText(session.totalDistanceCovered), label: "Distance", icon: "ruler")
                            statTile(value: elapsedText(session.elapsedTime),           label: "Time",     icon: "clock")
                            statTile(value: (session.liveSteps > 0 ? session.liveSteps : session.estimatedSteps).formatted(), label: "Steps", icon: activityMode.icon)
                        }
                        .padding(.horizontal)

                        if !newPRs.isEmpty {
                            VStack(spacing: 8) {
                                Text("New Personal Record\(newPRs.count > 1 ? "s" : "")! 🏅")
                                    .font(.caption.bold()).foregroundColor(.earthOrange)
                                HStack(spacing: 12) {
                                    ForEach(newPRs) { pr in
                                        VStack(spacing: 3) {
                                            Text(pr.emoji).font(.title2)
                                            Text(pr.title)
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.earthCream)
                                            Text(pr.valueText)
                                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                                .foregroundColor(.earthOrange)
                                        }
                                        .padding(.horizontal, 18).padding(.vertical, 10)
                                        .background(Color.earthOrange.opacity(0.1))
                                        .cornerRadius(12)
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.earthOrange.opacity(0.3), lineWidth: 1))
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }

                        if !walkedPets.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Your Crew")
                                    .font(.caption.bold()).foregroundColor(.earthMuted)
                                    .padding(.horizontal)
                                ForEach(walkedPets) { pet in
                                    petSummaryRow(pet: pet)
                                }
                            }
                        }

                        Button { saveToHistory() } label: {
                            Label(
                                savedToHistory ? "Saved to History" : "Save to Activity History",
                                systemImage: savedToHistory ? "checkmark.circle.fill" : "clock.arrow.circlepath"
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(savedToHistory ? Color.earthCard : Color.earthGreen)
                            .foregroundColor(savedToHistory ? .earthGreen : .white)
                            .fontWeight(.semibold)
                            .cornerRadius(12)
                        }
                        .disabled(savedToHistory)
                        .padding(.horizontal)

                        if session.trackPoints.count > 5 {
                            if showRouteNameField {
                                HStack(spacing: 10) {
                                    TextField("Route name…", text: $routeName)
                                        .foregroundColor(.earthCream)
                                        .padding(12)
                                        .background(Color.earthCard)
                                        .cornerRadius(10)
                                    Button("Save") { saveAsRoute() }
                                        .foregroundColor(.earthGreen)
                                        .fontWeight(.semibold)
                                }
                                .padding(.horizontal)
                            } else {
                                Button { showRouteNameField = true } label: {
                                    Label(
                                        savedAsRoute ? "Saved as Custom Route" : "Save as Custom Route",
                                        systemImage: savedAsRoute ? "checkmark.circle.fill" : "bookmark.fill"
                                    )
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                    .background(Color.earthCard)
                                    .foregroundColor(savedAsRoute ? .earthGreen : .earthCream)
                                    .fontWeight(.semibold)
                                    .cornerRadius(12)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.earthGreen.opacity(0.4), lineWidth: 1.5))
                                }
                                .disabled(savedAsRoute)
                                .padding(.horizontal)
                            }
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.vertical, 24)
                }
            }
            .navigationTitle("\(activityMode.sessionLabel) Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss(); onDone() }.foregroundColor(.earthGreen)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .fontWeight(.semibold).foregroundColor(.earthGreen)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(activityItems: shareItems)
        }
        .sheet(isPresented: $showMsgSheet) {
            if let phone = msgRecipient {
                MessageComposeSheet(recipients: [phone], body: msgBody)
            }
        }
        .onAppear {
            if session.totalDistanceCovered > 50 { saveToHistory() }
        }
    }

    @MainActor
    private func petSummaryRow(pet: PetProfile) -> some View {
        let meters = petDistances[pet.id] ?? 0
        let goalProgress = Double(Int(meters / 0.762)) / Double(max(1, pet.goalSteps))
        return VStack(spacing: 8) {
            PetWalkSummaryCard(
                pet: pet,
                sessionDistance: meters,
                sessionDuration: session.elapsedTime,
                goalProgress: goalProgress,
                date: session.startTime
            )
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button {
                    sharePetCard(pet: pet, meters: meters, goalProgress: goalProgress)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.earthCard)
                        .foregroundColor(pet.accentColor)
                        .cornerRadius(10)
                }

                if let phone = pet.ownerPhone, MFMessageComposeViewController.canSendText() {
                    Button {
                        let ownerFirst = pet.ownerName?.components(separatedBy: " ").first ?? "there"
                        let dist = MKDistanceFormatter.abbreviated.string(fromDistance: meters)
                        let steps = Int(meters / 0.762).formatted()
                        msgBody = "Hi \(ownerFirst)! Here's \(pet.name)'s walk summary 🐾\n\n📏 \(dist)  👟 \(steps) steps  ⏱ \(elapsedText(session.elapsedTime))\n\nSent from Wockett"
                        msgRecipient = phone
                        showMsgSheet = true
                    } label: {
                        Label("Message \(pet.ownerName?.components(separatedBy: " ").first ?? "Owner")", systemImage: "message.fill")
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.earthCard)
                            .foregroundColor(.earthGreen)
                            .cornerRadius(10)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    @MainActor
    private func sharePetCard(pet: PetProfile, meters: Double, goalProgress: Double) {
        let card = PetWalkSummaryCard(
            pet: pet,
            sessionDistance: meters,
            sessionDuration: session.elapsedTime,
            goalProgress: goalProgress,
            date: session.startTime
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3.0
        guard let image = renderer.uiImage else { return }
        shareItems = [image]
        showShareSheet = true
    }

    private func saveToHistory() {
        guard !savedToHistory else { return }
        let existingSessions = historyStore.sessions
        let saved = walkStore.buildAndSaveSession(
            petDistances: petDistances,
            activePetIds: Array(petDistances.keys),
            isCommunityRoute: false
        )
        guard let saved else { return }
        newPRs = checkNewPRs(newSession: saved, against: existingSessions)
        savedToHistory = true
        Task { await session.finishWorkoutSession() }
    }

    private func saveAsRoute() {
        let name = routeName.trimmingCharacters(in: .whitespaces).isEmpty ? "My \(activityMode.sessionLabel)" : routeName
        routeStore.save(CustomRoute(
            id: UUID(),
            name: name,
            waypoints: session.trackPoints.map { WaypointCoord($0) },
            totalDistance: session.totalDistanceCovered,
            isLoop: false,
            createdAt: Date()
        ))
        savedAsRoute = true
        showRouteNameField = false
    }

    private func statTile(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(.earthGreen).font(.title3)
            Text(value).font(.headline.bold()).foregroundColor(.earthCream)
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .background(Color.earthCard).cornerRadius(14)
    }
}
