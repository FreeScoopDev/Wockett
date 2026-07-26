import SwiftUI
import Combine
import MapKit
import CoreLocation
import HealthKit

// MARK: - Free Walk Manager

final class FreeWalkManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var trackPoints: [CLLocationCoordinate2D] = []
    @Published var totalDistance: Double = 0
    @Published var elapsedSeconds: Int = 0
    @Published var isTracking = false

    private(set) var startDate = Date()
    private var locationHistory: [CLLocation] = []
    private var workoutWriter: HealthWorkoutWriter?

    private let locationManager = CLLocationManager()
    private var lastLocation: CLLocation?
    private var timer: Timer?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5
    }

    var activityMode: ActivityMode = .walking

    func start() {
        guard !isTracking else { return }
        isTracking = true
        startDate = Date()
        locationManager.startUpdatingLocation()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.elapsedSeconds += 1 }
        }
        let capturedStart = startDate
        let activityType = activityMode.hkActivityType
        Task {
            let writer = HealthWorkoutWriter(activityType: activityType)
            await writer.start(at: capturedStart)
            await MainActor.run { self.workoutWriter = writer }
        }
    }

    func stop() {
        guard isTracking else { return }
        isTracking = false
        locationManager.stopUpdatingLocation()
        timer?.invalidate()
        timer = nil
    }

    func finishWorkoutSession() async {
        guard let writer = workoutWriter else { return }
        workoutWriter = nil
        await writer.finish(totalDistanceMeters: totalDistance, endDate: Date())
    }

    var estimatedSteps: Int { Int(totalDistance / 0.762) }

    var elapsedText: String {
        let h = elapsedSeconds / 3600
        let m = (elapsedSeconds % 3600) / 60
        let s = elapsedSeconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    var distanceText: String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: max(totalDistance, 0))
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            guard location.horizontalAccuracy > 0,
                  location.horizontalAccuracy < 30 else { continue }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let last = self.lastLocation {
                    self.totalDistance += location.distance(from: last)
                }
                self.lastLocation = location
                self.trackPoints.append(location.coordinate)
                self.locationHistory.append(location)
                self.workoutWriter?.addLocations([location])
            }
        }
    }
}

// MARK: - Free Walk View

struct FreeWalkView: View {
    @EnvironmentObject var petStore: PetStore
    @ObservedObject var historyStore: WalkHistoryStore
    @ObservedObject var routeStore: CustomRouteStore
    @Environment(\.dismiss) private var dismiss

    var activityMode: ActivityMode = .walking

    @StateObject private var walkManager = FreeWalkManager()
    @State private var showSummary = false
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    private var isCycling: Bool { activityMode == .cycling }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                if walkManager.trackPoints.count > 1 {
                    MapPolyline(coordinates: walkManager.trackPoints)
                        .stroke(isCycling ? Color(red: 0.13, green: 0.57, blue: 0.64) : Color.earthGreen, lineWidth: 5)
                }
                UserAnnotation()
            }
            .mapStyle(.standard)
            .ignoresSafeArea()

            VStack {
                // Stats HUD
                HStack(spacing: 0) {
                    hudStat(value: walkManager.distanceText, label: "Distance")
                    Divider().frame(height: 36)
                    hudStat(value: walkManager.elapsedText, label: "Time")
                    Divider().frame(height: 36)
                    hudStat(value: walkManager.estimatedSteps.formatted(), label: isCycling ? "Rotations" : "Steps")
                }
                .padding(.vertical, 14)
                .background(.ultraThinMaterial)
                .cornerRadius(18)
                .padding(.horizontal, 20)
                .padding(.top, 56)

                Spacer()

                Button {
                    walkManager.stop()
                    showSummary = true
                } label: {
                    Label(isCycling ? "Finish Ride" : "Finish Walk", systemImage: "checkmark.circle.fill")
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
        }
        .onAppear {
            walkManager.activityMode = activityMode
            walkManager.start()
        }
        .onDisappear { walkManager.stop() }
        .sheet(isPresented: $showSummary) {
            FreeWalkSummarySheet(
                walkManager: walkManager,
                historyStore: historyStore,
                routeStore: routeStore
            ) { dismiss() }
        }
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
}

// MARK: - Free Walk Summary Sheet

struct FreeWalkSummarySheet: View {
    @ObservedObject var walkManager: FreeWalkManager
    @ObservedObject var historyStore: WalkHistoryStore
    @ObservedObject var routeStore: CustomRouteStore
    @EnvironmentObject var petStore: PetStore
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var savedToHistory = false
    @State private var savedAsRoute = false
    @State private var showRouteNameField = false
    @State private var routeName = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 8) {
                            Text("🎉").font(.system(size: 52))
                            Text("Walk Complete!")
                                .font(.title2.bold()).foregroundColor(.earthCream)
                        }
                        .padding(.top, 8)

                        HStack(spacing: 12) {
                            statTile(value: walkManager.distanceText,                   label: "Distance", icon: "ruler")
                            statTile(value: walkManager.elapsedText,                    label: "Time",     icon: "clock")
                            statTile(value: walkManager.estimatedSteps.formatted(),     label: "Steps",    icon: "figure.walk")
                        }
                        .padding(.horizontal)

                        Button { saveToHistory() } label: {
                            Label(
                                savedToHistory ? "Saved to History" : "Save to Walk History",
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

                        if walkManager.trackPoints.count > 5 {
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
            .navigationTitle("Walk Summary")
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
        .onAppear {
            // Auto-save walks longer than 50 metres
            if walkManager.totalDistance > 50 { saveToHistory() }
        }
    }

    private func saveToHistory() {
        guard !savedToHistory else { return }
        let session = WalkSession(
            id: UUID(),
            routeName: walkManager.activityMode == .cycling ? "Free Ride" : "Free Walk",
            date: walkManager.startDate,
            elapsedTime: TimeInterval(walkManager.elapsedSeconds),
            totalDistance: walkManager.totalDistance,
            waypoints: walkManager.trackPoints.map { WaypointCoord($0) },
            lapCount: 1,
            isLoop: false,
            activePetIds: petStore.activePetIds,
            activityType: walkManager.activityMode.rawValue
        )
        historyStore.add(session)
        savedToHistory = true
        Task { await walkManager.finishWorkoutSession() }
    }

    private func saveAsRoute() {
        let name = routeName.trimmingCharacters(in: .whitespaces).isEmpty ? "My Walk" : routeName
        routeStore.save(CustomRoute(
            id: UUID(),
            name: name,
            waypoints: walkManager.trackPoints.map { WaypointCoord($0) },
            totalDistance: walkManager.totalDistance,
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
