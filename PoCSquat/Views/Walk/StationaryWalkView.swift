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

    private let purple = Color.accentIndoor
    private let purpleFill = Color.accentIndoorFill

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button { manager.stop(); dismiss() } label: {
                        Image(wkt: .close).wktIcon(.tab, tint: .earthMuted, filled: true)
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                    Label {
                        Text("Indoor Walk")
                    } icon: {
                        Image(wkt: .walkMotion).wktIcon(.row, tint: .earthCream)
                    }
                        .font(.headline)
                        .foregroundColor(.earthCream)
                    Spacer()
                    Color.clear.frame(width: 26, height: 26)
                }
                .padding(.horizontal, 24)
                .padding(.top, 56)

                Spacer()

                // Step counter ring
                ZStack {
                    Circle()
                        .stroke(purple.opacity(0.15), lineWidth: 18)
                    Circle()
                        .trim(from: 0, to: min(1.0, Double(manager.steps) / Double(max(1, dailyGoal))))
                        .stroke(purple, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.4), value: manager.steps)

                    VStack(spacing: 4) {
                        Text(manager.steps.formatted())
                            .font(.system(size: 52, weight: .black, design: .rounded))
                            .foregroundColor(.earthCream)
                        Text("steps")
                            .font(.subheadline)
                            .foregroundColor(.earthMuted)
                    }
                }
                .frame(width: 220, height: 220)
                .padding(.vertical, 32)

                // Stats row
                HStack(spacing: 0) {
                    statCell(value: manager.elapsedText,    label: "Time",     icon: "clock")
                    Divider().frame(height: 44)
                    statCell(value: manager.distanceText,   label: "Distance", icon: "ruler")
                    Divider().frame(height: 44)
                    statCell(value: manager.paceText,       label: "Pace",     icon: "speedometer")
                    Divider().frame(height: 44)
                    statCell(value: manager.cadenceText,    label: "Cadence",  icon: "waveform.path")
                }
                .padding(.vertical, 16)
                .background(Color.earthCard)
                .cornerRadius(18)
                .padding(.horizontal, 24)

                Spacer()

                if !petStore.pets.isEmpty {
                    HStack(spacing: 16) {
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
                                VStack(spacing: 2) {
                                    Text(pet.displayEmoji)
                                        .font(.title2)
                                        .opacity(pet.isActiveOnWalk ? 1.0 : 0.35)
                                        .scaleEffect(pet.isActiveOnWalk ? 1.0 : 0.85)
                                    Text(pet.name)
                                        .font(.caption2)
                                        .foregroundColor(pet.isActiveOnWalk ? .earthCream : .earthMuted)
                                }
                                .animation(.spring(duration: 0.2), value: pet.isActiveOnWalk)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }

                // Finish button
                Button {
                    flushAllActivePets()
                    manager.stop()
                    showSummary = true
                } label: {
                    Label {
                        Text("Finish Workout")
                    } icon: {
                        Image(wkt: .success).wktIcon(.row, tint: .white, filled: true, onFill: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(purpleFill)
                    .foregroundColor(.white)
                    .font(.headline)
                    .cornerRadius(14)
                    .padding(.horizontal, 24)
                }
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

    private func statCell(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(purple)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.earthCream)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity)
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
    private let purpleFill = Color.accentIndoorFill

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 8) {
                            Text("🏋️").font(.system(size: 52))
                            Text("Workout Complete!")
                                .font(.title2.bold()).foregroundColor(.earthCream)
                        }
                        .padding(.top, 8)

                        HStack(spacing: 12) {
                            tile(manager.steps.formatted(),  "Steps",    "figure.walk")
                            tile(manager.distanceText,       "Distance", "ruler")
                            tile(manager.elapsedText,        "Time",     "clock")
                        }
                        .padding(.horizontal)

                        Button { saveSession() } label: {
                            Label(
                                saved ? "Saved to History" : "Save to Walk History",
                                systemImage: saved ? "checkmark.circle.fill" : "clock.arrow.circlepath"
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(saved ? Color.earthCard : purpleFill)
                            .foregroundColor(saved ? purple : .white)
                            .fontWeight(.semibold)
                            .cornerRadius(12)
                        }
                        .disabled(saved)
                        .padding(.horizontal)

                        Spacer(minLength: 40)
                    }
                    .padding(.vertical, 24)
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

    private func tile(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(purple).font(.title3)
            Text(value).font(.headline.bold()).foregroundColor(.earthCream)
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .background(Color.earthCard).cornerRadius(14)
    }
}
