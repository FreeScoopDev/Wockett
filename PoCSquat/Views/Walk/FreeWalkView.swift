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
