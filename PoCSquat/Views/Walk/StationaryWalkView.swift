import SwiftUI
import Combine
import CoreMotion
import HealthKit
import MapKit

// MARK: - Stationary Walk Manager

final class StationaryWalkManager: ObservableObject {
    @Published var steps: Int = 0
    @Published var elapsedSeconds: Int = 0
    @Published var isTracking = false

    private(set) var startDate = Date()
    private let pedometer = CMPedometer()
    private var timer: Timer?
    private var workoutWriter: HealthWorkoutWriter?

    var estimatedDistanceMeters: Double { Double(steps) * 0.762 }

    var distanceText: String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: max(estimatedDistanceMeters, 0))
    }

    var elapsedText: String {
        let h = elapsedSeconds / 3600
        let m = (elapsedSeconds % 3600) / 60
        let s = elapsedSeconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    var paceText: String {
        guard elapsedSeconds > 10, steps > 50 else { return "—" }
        let secsPerKm = Double(elapsedSeconds) / (estimatedDistanceMeters / 1000)
        let mins = Int(secsPerKm) / 60
        let secs = Int(secsPerKm) % 60
        return String(format: "%d'%02d\"/km", mins, secs)
    }

    var cadenceText: String {
        guard elapsedSeconds > 5 else { return "—" }
        let spm = Double(steps) / (Double(elapsedSeconds) / 60.0)
        return String(format: "%.0f spm", spm)
    }

    func start() {
        guard !isTracking, CMPedometer.isStepCountingAvailable() else { return }
        isTracking = true
        startDate  = Date()
        steps      = 0

        pedometer.startUpdates(from: startDate) { [weak self] data, error in
            guard let self, let data, error == nil else { return }
            DispatchQueue.main.async { self.steps = data.numberOfSteps.intValue }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.elapsedSeconds = Int(Date().timeIntervalSince(self.startDate)) }
        }

        let capturedStart = startDate
        Task {
            let writer = HealthWorkoutWriter(activityType: .walking, isIndoor: true)
            await writer.start(at: capturedStart)
            DispatchQueue.main.async { self.workoutWriter = writer }
        }
    }

    func stop() {
        guard isTracking else { return }
        isTracking = false
        pedometer.stopUpdates()
        timer?.invalidate()
        timer = nil
    }

    func finishWorkout() async {
        guard let writer = workoutWriter else { return }
        workoutWriter = nil
        await writer.finish(totalDistanceMeters: estimatedDistanceMeters, endDate: Date())
    }
}

// MARK: - Stationary Walk View

struct StationaryWalkView: View {
    @ObservedObject var historyStore: WalkHistoryStore
    var dailyGoal: Int = 10_000
    @EnvironmentObject var petStore: PetStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var manager = StationaryWalkManager()
    @State private var showSummary = false
    @State private var petActiveSinceSteps: [UUID: Int] = [:]

    /// Indoor's activity colour, for icons only: the step ring is the user's
    /// goal (orange, `WktGoalRing`) and Finish is the screen's one primary action.
    private let purple = Color.accentIndoor

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    WktRoundIconButton(symbol: .dismiss, label: "Close") { manager.stop(); dismiss() }
                    Spacer()
                    HStack(spacing: 8) {
                        Image(wkt: .walkMotion).wktIcon(.row, tint: purple)
                        Text("Indoor Walk")
                            .font(.wktRowTitle)
                            .foregroundColor(.earthCream)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, WktSpacing.screen)
                .padding(.top, 56)

                Spacer()

                // Step counter ring
                WktGoalRing(progress: Double(manager.steps) / Double(max(1, dailyGoal)), lineWidth: 18) {
                    VStack(spacing: 4) {
                        Text(manager.steps.formatted())
                            .font(.wktHeading(52))
                            .foregroundColor(.earthCream)
                            .minimumScaleFactor(0.6)
                        Text("steps")
                            .font(.wktBodyText)
                            .foregroundColor(.earthMuted)
                    }
                }
                .frame(width: 236, height: 236)
                .padding(.vertical, 32)
                .accessibilityElement(children: .combine)

                // Stats row
                HStack(spacing: 0) {
                    statCell(value: manager.elapsedText,    label: "Time",     icon: .time)
                    columnDivider
                    statCell(value: manager.distanceText,   label: "Distance", icon: .distance)
                    columnDivider
                    statCell(value: manager.paceText,       label: "Pace",     icon: .pace)
                    columnDivider
                    statCell(value: manager.cadenceText,    label: "Cadence",  icon: .cadence)
                }
                .wktCard(padding: 14)
                .padding(.horizontal, WktSpacing.screen)

                Spacer()

                if !petStore.pets.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(petStore.pets) { pet in
                            Button {
                                let willActivate = !pet.isActiveOnWalk
                                let currentSteps = manager.steps
                                petStore.setActive(pet.id, active: willActivate)
                                if willActivate {
                                    petActiveSinceSteps[pet.id] = currentSteps
                                } else {
                                    if let since = petActiveSinceSteps[pet.id] {
                                        let deltaSteps = max(0, currentSteps - since)
                                        if deltaSteps > 50, let p = petStore.pets.first(where: { $0.id == pet.id }) {
                                            historyStore.add(WalkSession(
                                                id: UUID(), routeName: "\(p.name)'s Indoor Walk",
                                                date: manager.startDate, elapsedTime: 0,
                                                totalDistance: Double(deltaSteps) * 0.762,
                                                waypoints: [], lapCount: 1, isLoop: false,
                                                activePetIds: [p.id], activityType: ActivityMode.stationary.rawValue
                                            ))
                                        }
                                    }
                                    petActiveSinceSteps.removeValue(forKey: pet.id)
                                }
                            } label: {
                                // The session screen's crew chip: green when on this walk.
                                HStack(spacing: 6) {
                                    Text(pet.displayEmoji) // the pet's own emoji (data)
                                    Text(pet.name).font(.wktLabel)
                                }
                                .foregroundColor(pet.isActiveOnWalk ? .white : .earthCream)
                                .padding(.horizontal, 14)
                                .frame(height: 40)
                                .background(pet.isActiveOnWalk ? Color.earthGreenFill : Color.earthRaised, in: Capsule())
                                .animation(.spring(duration: 0.2), value: pet.isActiveOnWalk)
                            }
                            .accessibilityLabel(pet.isActiveOnWalk ? "Remove \(pet.name) from walk" : "Add \(pet.name) to walk")
                            .accessibilityAddTraits(pet.isActiveOnWalk ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 12)
                }

                // Finish button
                WktPrimaryButton(title: "Finish Workout", symbol: .success) {
                    flushAllActivePets()
                    manager.stop()
                    showSummary = true
                }
                .padding(.horizontal, WktSpacing.screen)
                .padding(.bottom, 48)
            }
        }
        .onAppear {
            manager.start()
            for pet in petStore.activePets {
                petActiveSinceSteps[pet.id] = 0
            }
        }
        .onDisappear { manager.stop() }
        .sheet(isPresented: $showSummary) {
            StationarySummarySheet(manager: manager, historyStore: historyStore) {
                dismiss()
            }
        }
    }

    private func flushAllActivePets() {
        let currentSteps = manager.steps
        for (petId, sinceSteps) in petActiveSinceSteps {
            guard let pet = petStore.pets.first(where: { $0.id == petId }) else { continue }
            let deltaSteps = max(0, currentSteps - sinceSteps)
            guard deltaSteps > 50 else { continue }
            historyStore.add(WalkSession(
                id: UUID(), routeName: "\(pet.name)'s Indoor Walk",
                date: manager.startDate, elapsedTime: 0,
                totalDistance: Double(deltaSteps) * 0.762,
                waypoints: [], lapCount: 1, isLoop: false,
                activePetIds: [pet.id], activityType: ActivityMode.stationary.rawValue
            ))
        }
        petActiveSinceSteps.removeAll()
    }

    private var columnDivider: some View {
        Rectangle().fill(Color.earthTrack).frame(width: 1, height: 44)
    }

    private func statCell(value: String, label: String, icon: WktSymbol) -> some View {
        VStack(spacing: 4) {
            Image(wkt: icon).wktIcon(.inline, tint: purple)
            Text(value)
                .font(.wktRowTitle.monospacedDigit())
                .foregroundColor(.earthCream)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.wktLabel)
                .foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stationary Summary Sheet

private struct StationarySummarySheet: View {
    @ObservedObject var manager: StationaryWalkManager
    @ObservedObject var historyStore: WalkHistoryStore
    @EnvironmentObject var petStore: PetStore
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var saved = false

    private let purple = Color.accentIndoor

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: WktSpacing.betweenSections) {
                        VStack(spacing: 12) {
                            WktIconBadge(symbol: .indoor, tint: purple, size: 64)
                            Text("Workout complete!")
                                .font(.wktCardTitle).foregroundColor(.earthCream)
                        }
                        .padding(.top, 8)

                        HStack(spacing: WktSpacing.betweenCards) {
                            tile(manager.steps.formatted(),  "Steps",    .steps)
                            tile(manager.distanceText,       "Distance", .distance)
                            tile(manager.elapsedText,        "Time",     .time)
                        }

                        Button { saveSession() } label: {
                            if saved {
                                WktSecondaryLabel(title: "Saved to History", symbol: .success)
                            } else {
                                WktPrimaryLabel(title: "Save to Walk History", symbol: .history)
                            }
                        }
                        .buttonStyle(BounceButtonStyle(scale: 0.98))
                        .disabled(saved)

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, WktSpacing.screen)
                    .padding(.vertical, WktSpacing.betweenSections)
                }
            }
            .navigationTitle("Indoor Walk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss(); onDone() }.foregroundColor(.earthGreen)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            if manager.steps > 100 { saveSession() }
        }
    }

    private func saveSession() {
        guard !saved else { return }
        let session = WalkSession(
            id: UUID(),
            routeName: "Indoor Walk",
            date: manager.startDate,
            elapsedTime: TimeInterval(manager.elapsedSeconds),
            totalDistance: manager.estimatedDistanceMeters,
            waypoints: [],
            lapCount: 1,
            isLoop: false,
            activePetIds: [],
            activityType: ActivityMode.stationary.rawValue
        )
        historyStore.add(session)
        saved = true
        Task { await manager.finishWorkout() }
    }

    private func tile(_ value: String, _ label: String, _ icon: WktSymbol) -> some View {
        WktIconStatTile(value: value, label: label, symbol: icon, tint: purple)
    }
}
