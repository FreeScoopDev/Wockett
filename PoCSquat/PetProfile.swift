import Combine
import Foundation
import MapKit
import SwiftUI

// MARK: - Pet Profile

struct PetProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var species: String = "Dog"
    var breed: String?
    var goalSteps: Int = 10_000
    var accentColorIndex: Int = 0
    var isActiveOnWalk: Bool = false
    var customEmoji: String?

    var displayEmoji: String { customEmoji ?? emoji }

    static let accentColors: [Color] = [
        Color(red: 0.78, green: 0.33, blue: 0.22),  // terracotta
        Color(red: 0.85, green: 0.60, blue: 0.15),  // amber
        Color(red: 0.28, green: 0.49, blue: 0.84),  // slate blue
        Color(red: 0.67, green: 0.32, blue: 0.64),  // mauve
        Color(red: 0.40, green: 0.63, blue: 0.38),  // sage
    ]

    var accentColor: Color {
        Self.accentColors[accentColorIndex % Self.accentColors.count]
    }

    var emoji: String {
        switch species.lowercased() {
        case "dog":    return "🐕"
        case "cat":    return "🐈"
        case "rabbit": return "🐇"
        case "bird":   return "🐦"
        default:       return "🐾"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, species, breed, goalSteps, accentColorIndex, isActiveOnWalk, customEmoji
    }
}

// MARK: - Pet Store

@MainActor
final class PetStore: ObservableObject {
    @Published var pets: [PetProfile] = []
    private let udKey = "petProfiles_v2"

    init() { load() }

    var activePets: [PetProfile] { pets.filter(\.isActiveOnWalk) }
    var activePetIds: [UUID] { activePets.map(\.id) }

    func add(_ pet: PetProfile) { pets.append(pet); persist() }

    func update(_ pet: PetProfile) {
        guard let i = pets.firstIndex(where: { $0.id == pet.id }) else { return }
        pets[i] = pet; persist()
    }

    func remove(id: UUID) {
        pets.removeAll { $0.id == id }; persist()
    }

    func setActive(_ id: UUID, active: Bool) {
        guard let i = pets.firstIndex(where: { $0.id == id }) else { return }
        pets[i].isActiveOnWalk = active; persist()
    }

    func todaySteps(for pet: PetProfile, in sessions: [WalkSession]) -> Int {
        let cal = Calendar.current
        return sessions
            .filter { cal.isDateInToday($0.date) && $0.activePetIds.contains(pet.id) }
            .reduce(0) { $0 + $1.estimatedSteps }
    }

    func totalWalks(for pet: PetProfile, in sessions: [WalkSession]) -> Int {
        sessions.filter { $0.activePetIds.contains(pet.id) }.count
    }

    func totalDistance(for pet: PetProfile, in sessions: [WalkSession]) -> Double {
        sessions
            .filter { $0.activePetIds.contains(pet.id) }
            .reduce(0) { $0 + $1.totalDistance }
    }

    func weeklySteps(for pet: PetProfile, in sessions: [WalkSession]) -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return sessions
            .filter { $0.date >= cutoff && $0.activePetIds.contains(pet.id) }
            .reduce(0) { $0 + $1.estimatedSteps }
    }

    func weeklyDistance(for pet: PetProfile, in sessions: [WalkSession]) -> Double {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return sessions
            .filter { $0.date >= cutoff && $0.activePetIds.contains(pet.id) }
            .reduce(0) { $0 + $1.totalDistance }
    }

    func recentSessions(for pet: PetProfile, in sessions: [WalkSession]) -> [WalkSession] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return sessions
            .filter { $0.date >= cutoff && $0.activePetIds.contains(pet.id) }
            .sorted { $0.date > $1.date }
    }

    func walkStreak(for pet: PetProfile, in sessions: [WalkSession]) -> Int {
        let cal = Calendar.current
        let walkedDays = Set(
            sessions
                .filter { $0.activePetIds.contains(pet.id) }
                .map { cal.startOfDay(for: $0.date) }
        ).sorted(by: >)
        guard !walkedDays.isEmpty else { return 0 }
        var streak = 0
        var expected = cal.startOfDay(for: Date())
        if !walkedDays.contains(expected) {
            expected = cal.date(byAdding: .day, value: -1, to: expected) ?? expected
            guard walkedDays.contains(expected) else { return 0 }
        }
        for day in walkedDays {
            if day == expected {
                streak += 1
                expected = cal.date(byAdding: .day, value: -1, to: expected) ?? expected
            } else if day < expected {
                break
            }
        }
        return streak
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(pets) else { return }
        UserDefaults.standard.set(data, forKey: udKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([PetProfile].self, from: data)
        else { return }
        pets = decoded
    }
}

// MARK: - Pet Completion (walk complete animation data)

struct PetCompletion {
    let pet: PetProfile
    let progress: Double   // 0–1, including the just-completed walk
}

// MARK: - Pet Management View

struct PetManagementView: View {
    @EnvironmentObject var petStore: PetStore
    @ObservedObject var historyStore: WalkHistoryStore
    let defaultGoal: Int

    @State private var showAddPet  = false
    @State private var editingPet: PetProfile?

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            if petStore.pets.isEmpty { emptyState } else { petList }
        }
        .navigationTitle("My Pets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAddPet = true } label: {
                    Image(systemName: "plus").foregroundColor(.earthGreen)
                }
            }
        }
        .sheet(isPresented: $showAddPet) {
            PetEditorSheet(pet: nil, defaultGoal: defaultGoal) { petStore.add($0) }
        }
        .sheet(item: $editingPet) { pet in
            PetEditorSheet(pet: pet, defaultGoal: pet.goalSteps) {
                petStore.update($0)
            } onDelete: {
                petStore.remove(id: pet.id)
            }
        }
    }

    private var petList: some View {
        List {
            ForEach(petStore.pets) { pet in
                PetManagementRow(pet: pet, historyStore: historyStore) { editingPet = pet }
                    .listRowBackground(Color.earthCard)
                    .listRowSeparatorTint(Color.earthMuted.opacity(0.2))
            }
            Button { showAddPet = true } label: {
                Label("Add a Pet", systemImage: "plus.circle.fill")
                    .foregroundColor(.earthGreen)
                    .padding(.vertical, 4)
            }
            .listRowBackground(Color.earthCard)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Text("🐾").font(.system(size: 64))
            Text("No Pets Yet").font(.headline).foregroundColor(.earthCream)
            Text("Add a pet to track their walks alongside yours.")
                .font(.subheadline).foregroundColor(.earthMuted)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Button { showAddPet = true } label: {
                Label("Add a Pet", systemImage: "plus.circle.fill")
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(Color.earthGreen).foregroundColor(.white)
                    .fontWeight(.semibold).cornerRadius(12)
            }
        }
    }
}

// MARK: - Pet Management Row

private struct PetManagementRow: View {
    @EnvironmentObject var petStore: PetStore
    let pet: PetProfile
    @ObservedObject var historyStore: WalkHistoryStore
    let onEdit: () -> Void

    private var totalWalks: Int { petStore.totalWalks(for: pet, in: historyStore.sessions) }
    private var totalDistText: String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: petStore.totalDistance(for: pet, in: historyStore.sessions))
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(pet.accentColor.opacity(0.2)).frame(width: 48, height: 48)
                Text(pet.emoji).font(.system(size: 24))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(pet.name).font(.headline).foregroundColor(.earthCream)
                    if let breed = pet.breed {
                        Text("· \(breed)").font(.caption).foregroundColor(.earthMuted)
                    }
                }
                HStack(spacing: 10) {
                    Label("\(totalWalks) walks", systemImage: "figure.walk")
                    Label(totalDistText, systemImage: "ruler")
                }
                .font(.footnote).foregroundColor(.earthMuted)
                Text("Goal: \(pet.goalSteps.formatted()) steps")
                    .font(.caption).foregroundColor(pet.accentColor)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { pet.isActiveOnWalk },
                set: { petStore.setActive(pet.id, active: $0) }
            ))
            .labelsHidden()
            .tint(pet.accentColor)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
    }
}

// MARK: - Pet Editor Sheet

struct PetEditorSheet: View {
    var pet: PetProfile?
    let defaultGoal: Int
    let onSave: (PetProfile) -> Void
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var name        = ""
    @State private var species     = "Dog"
    @State private var breed       = ""
    @State private var goalText    = ""
    @State private var colorIndex  = 0
    @State private var emojiText   = ""

    private let speciesOptions = ["Dog", "Cat", "Rabbit", "Bird", "Other"]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        Text(previewEmoji).font(.system(size: 64)).padding(.top, 8)

                        field(label: "Name") {
                            TextField("Buddy, Luna, Max…", text: $name).foregroundColor(.earthCream)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Type").font(.caption.bold()).foregroundColor(.earthMuted).padding(.horizontal, 4)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(speciesOptions, id: \.self) { s in
                                        Button { species = s } label: {
                                            Text(s)
                                                .font(.caption.bold())
                                                .padding(.horizontal, 14).padding(.vertical, 8)
                                                .background(species == s ? Color.earthGreen : Color.earthCard)
                                                .foregroundColor(species == s ? .white : .earthCream)
                                                .cornerRadius(20)
                                        }
                                    }
                                }
                            }
                        }

                        field(label: "Breed (optional)") {
                            TextField("Golden Retriever, Mixed…", text: $breed).foregroundColor(.earthCream)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Custom Emoji (optional)")
                                .font(.caption.bold()).foregroundColor(.earthMuted).padding(.horizontal, 4)
                            HStack(spacing: 10) {
                                Text(emojiText.isEmpty ? previewEmoji : emojiText)
                                    .font(.system(size: 36))
                                TextField("Tap to change…", text: $emojiText)
                                    .foregroundColor(.earthCream)
                                    .padding(12)
                                    .background(Color.earthCard)
                                    .cornerRadius(10)
                                if !emojiText.isEmpty {
                                    Button { emojiText = "" } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundColor(.earthMuted)
                                    }
                                }
                            }
                        }

                        field(label: "Daily Step Goal") {
                            TextField("10000", text: $goalText).keyboardType(.numberPad).foregroundColor(.earthCream)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Color").font(.caption.bold()).foregroundColor(.earthMuted).padding(.horizontal, 4)
                            HStack(spacing: 12) {
                                ForEach(0..<PetProfile.accentColors.count, id: \.self) { i in
                                    Button { colorIndex = i } label: {
                                        ZStack {
                                            Circle().fill(PetProfile.accentColors[i]).frame(width: 32, height: 32)
                                            if colorIndex == i {
                                                Image(systemName: "checkmark").font(.caption.bold()).foregroundColor(.white)
                                            }
                                        }
                                        .overlay(Circle().stroke(colorIndex == i ? Color.white.opacity(0.8) : Color.clear, lineWidth: 2))
                                    }
                                }
                            }
                        }

                        if onDelete != nil {
                            Button(role: .destructive) { onDelete?(); dismiss() } label: {
                                Text("Remove \(name.isEmpty ? "Pet" : name)")
                                    .font(.subheadline).foregroundColor(.red.opacity(0.8))
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle(pet != nil ? "Edit Pet" : "Add a Pet")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                name       = pet?.name ?? ""
                species    = pet?.species ?? "Dog"
                breed      = pet?.breed ?? ""
                goalText   = "\(pet?.goalSteps ?? defaultGoal)"
                colorIndex = pet?.accentColorIndex ?? 0
                emojiText  = pet?.customEmoji ?? ""
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .foregroundColor(.earthGreen)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.earthMuted)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                        .fontWeight(.semibold).foregroundColor(.earthGreen)
                }
            }
        }
        .presentationDetents([.large])
    }

    private var previewEmoji: String {
        switch species.lowercased() {
        case "dog": return "🐕"; case "cat": return "🐈"
        case "rabbit": return "🐇"; case "bird": return "🐦"
        default: return "🐾"
        }
    }

    private func field<C: View>(label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.bold()).foregroundColor(.earthMuted).padding(.horizontal, 4)
            content().padding(14).background(Color.earthCard).cornerRadius(12)
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var updated = pet ?? PetProfile(name: trimmed)
        updated.name             = trimmed
        updated.species          = species
        updated.breed            = breed.trimmingCharacters(in: .whitespaces).isEmpty ? nil : breed.trimmingCharacters(in: .whitespaces)
        updated.goalSteps        = max(1_000, Int(goalText) ?? defaultGoal)
        updated.accentColorIndex = colorIndex
        updated.customEmoji      = emojiText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String(emojiText.trimmingCharacters(in: .whitespaces).prefix(2))
        if pet == nil { updated.isActiveOnWalk = true }
        onSave(updated)
        dismiss()
    }
}
