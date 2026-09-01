import Combine
import Foundation
import MapKit
import SwiftUI
import SwiftData
import UIKit
import UserNotifications

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
    var ownerName: String?
    var ownerPhone: String?

    init(id: UUID = UUID(), name: String, species: String = "Dog", breed: String? = nil,
         goalSteps: Int = 10_000, accentColorIndex: Int = 0, isActiveOnWalk: Bool = false,
         customEmoji: String? = nil, ownerName: String? = nil, ownerPhone: String? = nil) {
        self.id               = id
        self.name             = name
        self.species          = species
        self.breed            = breed
        self.goalSteps        = goalSteps
        self.accentColorIndex = accentColorIndex
        self.isActiveOnWalk   = isActiveOnWalk
        self.customEmoji      = customEmoji
        self.ownerName        = ownerName
        self.ownerPhone       = ownerPhone
    }

    var hasOwnerContact: Bool { ownerName != nil || ownerPhone != nil }

    var displayEmoji: String { customEmoji ?? emoji }

    // Light values are the original fixed palette; dark values are lifted
    // (brighter, slightly desaturated) so they read against `earthBg` instead
    // of going muddy the way the old fixed single-mode colors did.
    static let accentColors: [Color] = [
        Color(UIColor { tc in tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.90, green: 0.50, blue: 0.38, alpha: 1)   // terracotta (lifted)
            : UIColor(red: 0.78, green: 0.33, blue: 0.22, alpha: 1) }),
        Color(UIColor { tc in tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.95, green: 0.72, blue: 0.32, alpha: 1)   // amber (lifted)
            : UIColor(red: 0.85, green: 0.60, blue: 0.15, alpha: 1) }),
        Color(UIColor { tc in tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.45, green: 0.62, blue: 0.92, alpha: 1)   // slate blue (lifted)
            : UIColor(red: 0.28, green: 0.49, blue: 0.84, alpha: 1) }),
        Color(UIColor { tc in tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.82, green: 0.50, blue: 0.80, alpha: 1)   // mauve (lifted)
            : UIColor(red: 0.67, green: 0.32, blue: 0.64, alpha: 1) }),
        Color(UIColor { tc in tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.55, green: 0.78, blue: 0.52, alpha: 1)   // sage (lifted)
            : UIColor(red: 0.40, green: 0.63, blue: 0.38, alpha: 1) }),
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
        case id, name, species, breed, goalSteps, accentColorIndex, isActiveOnWalk, customEmoji, ownerName, ownerPhone
    }
}

// MARK: - Pet Store

@MainActor
final class PetStore: ObservableObject {
    @Published var pets: [PetProfile] = []

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        load()
    }

    var activePets: [PetProfile] { pets.filter(\.isActiveOnWalk) }
    var activePetIds: [UUID] { activePets.map(\.id) }

    func add(_ pet: PetProfile) {
        context.insert(PetProfileRecord(from: pet))
        save()
        pets.append(pet)
    }

    func update(_ pet: PetProfile) {
        guard let i = pets.firstIndex(where: { $0.id == pet.id }) else { return }
        pets[i] = pet
        if let record = fetchRecord(id: pet.id) {
            record.name             = pet.name
            record.species          = pet.species
            record.breed            = pet.breed
            record.goalSteps        = pet.goalSteps
            record.accentColorIndex = pet.accentColorIndex
            record.isActiveOnWalk   = pet.isActiveOnWalk
            record.customEmoji      = pet.customEmoji
            record.ownerName        = pet.ownerName
            record.ownerPhone       = pet.ownerPhone
        }
        save()
    }

    func remove(id: UUID) {
        pets.removeAll { $0.id == id }
        if let record = fetchRecord(id: id) { context.delete(record) }
        save()
    }

    func setActive(_ id: UUID, active: Bool) {
        guard let i = pets.firstIndex(where: { $0.id == id }) else { return }
        pets[i].isActiveOnWalk = active
        fetchRecord(id: id)?.isActiveOnWalk = active
        save()
    }

    // Backward-compatible helpers: use petDistances when present, fall back to activePetIds.
    private func petParticipated(_ pet: PetProfile, in session: WalkSession) -> Bool {
        session.petDistances.isEmpty
            ? session.activePetIds.contains(pet.id)
            : (session.petDistances[pet.id] ?? 0) > 0
    }

    private func petWalkedMeters(_ pet: PetProfile, in session: WalkSession) -> Double {
        if session.petDistances.isEmpty {
            return session.activePetIds.contains(pet.id) ? session.totalDistance : 0
        }
        return session.petDistances[pet.id] ?? 0
    }

    func todaySteps(for pet: PetProfile, in sessions: [WalkSession]) -> Int {
        let cal = Calendar.current
        return sessions
            .filter { cal.isDateInToday($0.date) }
            .reduce(0) { $0 + Int(petWalkedMeters(pet, in: $1) / 0.762) }
    }

    func totalWalks(for pet: PetProfile, in sessions: [WalkSession]) -> Int {
        sessions.filter { petParticipated(pet, in: $0) }.count
    }

    func totalDistance(for pet: PetProfile, in sessions: [WalkSession]) -> Double {
        sessions.reduce(0) { $0 + petWalkedMeters(pet, in: $1) }
    }

    func weeklySteps(for pet: PetProfile, in sessions: [WalkSession]) -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return sessions
            .filter { $0.date >= cutoff }
            .reduce(0) { $0 + Int(petWalkedMeters(pet, in: $1) / 0.762) }
    }

    func weeklyDistance(for pet: PetProfile, in sessions: [WalkSession]) -> Double {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return sessions
            .filter { $0.date >= cutoff }
            .reduce(0) { $0 + petWalkedMeters(pet, in: $1) }
    }

    func recentSessions(for pet: PetProfile, in sessions: [WalkSession]) -> [WalkSession] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return sessions
            .filter { $0.date >= cutoff && petParticipated(pet, in: $0) }
            .sorted { $0.date > $1.date }
    }

    func walkStreak(for pet: PetProfile, in sessions: [WalkSession]) -> Int {
        let cal = Calendar.current
        let walkedDays = Set(
            sessions
                .filter { petParticipated(pet, in: $0) }
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

    func schedulePetNudge(sessions: [WalkSession]) async {
        guard UserDefaults.standard.object(forKey: "notif_petNudge") as? Bool ?? true else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["pet-nudge"])

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let cal = Calendar.current
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: Date()) ?? Date()

        let overduePets = activePets.filter { pet in
            let lastWalk = sessions
                .filter { petParticipated(pet, in: $0) }
                .map(\.date)
                .max()
            guard let last = lastWalk else { return true }
            return last < twoDaysAgo
        }

        guard !overduePets.isEmpty else { return }

        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.day = (comps.day ?? 0) + 1
        comps.hour = 9; comps.minute = 0
        guard let fireDate = cal.date(from: comps), fireDate > Date() else { return }

        let names = overduePets.prefix(2).map(\.name).joined(separator: " & ")
        let extra = overduePets.count > 2 ? " +\(overduePets.count - 2)" : ""
        let content = UNMutableNotificationContent()
        content.title = "\(names)\(extra) could use a walk! 🐾"
        content.body = overduePets.count == 1
            ? "\(overduePets[0].name) hasn't been on a walk in a couple of days."
            : "Your pets haven't walked in a couple of days."
        content.sound = .default

        try? await center.add(UNNotificationRequest(
            identifier: "pet-nudge",
            content: content,
            trigger: UNCalendarNotificationTrigger(
                dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                repeats: false
            )
        ))
    }

    // MARK: - Private helpers

    private func save() { try? context.save() }

    private func load() {
        let descriptor = FetchDescriptor<PetProfileRecord>()
        pets = (try? context.fetch(descriptor))?.map { $0.toPetProfile() } ?? []
    }

    private func fetchRecord(id: UUID) -> PetProfileRecord? {
        var descriptor = FetchDescriptor<PetProfileRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
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
                    .background(Color.earthGreenFill).foregroundColor(.white)
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
    @State private var name             = ""
    @State private var species          = "Dog"
    @State private var breed            = ""
    @State private var goalText         = ""
    @State private var colorIndex       = 0
    @State private var emojiText        = ""
    @State private var hasOwnerContact  = false
    @State private var ownerNameText    = ""
    @State private var ownerPhoneText   = ""

    private let speciesOptions = ["Dog", "Cat", "Rabbit", "Bird", "Other"]

    private static let breedGoalSuggestions: [(keywords: [String], steps: Int)] = [
        (["border collie"],                                      18_000),
        (["husky", "malamute"],                                  16_000),
        (["vizsla", "weimaraner", "pointer", "setter"],          15_000),
        (["dalmatian", "aussie", "australian shepherd"],         14_000),
        (["labrador", "lab", "golden retriever"],                13_000),
        (["german shepherd", "doberman", "rottweiler", "boxer"], 12_000),
        (["beagle", "poodle", "schnauzer"],                      10_000),
        (["cocker spaniel", "corgi"],                             9_000),
        (["bulldog", "basset hound"],                             5_000),
        (["french bulldog", "shih tzu", "chihuahua"],             5_000),
        (["pomeranian", "maltese", "dachshund", "yorkie", "yorkshire"], 5_000),
        (["great dane", "mastiff", "saint bernard"],              6_000),
        (["persian", "siamese", "maine coon", "bengal",
           "ragdoll", "british shorthair"],                       3_000),
        (["mixed", "mutt"],                                       8_000),
    ]

    private var suggestedGoal: Int? {
        let lower = breed.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return nil }
        return Self.breedGoalSuggestions.first { entry in
            entry.keywords.contains { lower.contains($0) }
        }?.steps
    }

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
                                                .background(species == s ? Color.earthGreenFill : Color.earthCard)
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

                        if breed.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text("Enter a breed to get a step goal suggestion. For mixed breeds, use the dominant breed (e.g. 'Labrador').")
                                .font(.caption)
                                .foregroundColor(.earthMuted)
                                .padding(.horizontal, 4)
                        } else if suggestedGoal == nil {
                            Text("No suggestion for this breed — try a common name like 'Labrador', 'Poodle', or 'Golden Retriever'.")
                                .font(.caption)
                                .foregroundColor(.earthMuted)
                                .padding(.horizontal, 4)
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

                        if let suggested = suggestedGoal, Int(goalText) != suggested {
                            Button { goalText = "\(suggested)" } label: {
                                Label("Suggested for this breed: \(suggested.formatted()) steps", systemImage: "lightbulb.fill")
                                    .font(.caption.bold())
                                    .foregroundColor(.earthOrange)
                            }
                            .padding(.horizontal, 4)
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

                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $hasOwnerContact.animation()) {
                                Label("This pet has an owner to notify", systemImage: "person.fill")
                                    .font(.subheadline)
                                    .foregroundColor(.earthCream)
                            }
                            .tint(.earthGreenFill)
                            .padding(.horizontal, 4)

                            if hasOwnerContact {
                                field(label: "Owner Name") {
                                    TextField("Jane Smith", text: $ownerNameText).foregroundColor(.earthCream)
                                }
                                field(label: "Owner Phone") {
                                    TextField("+1 555 000 0000", text: $ownerPhoneText)
                                        .keyboardType(.phonePad)
                                        .foregroundColor(.earthCream)
                                }
                                Text("Used to quickly message the owner after walks. Stored only on this device.")
                                    .font(.caption)
                                    .foregroundColor(.earthMuted)
                                    .padding(.horizontal, 4)
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
                name             = pet?.name ?? ""
                species          = pet?.species ?? "Dog"
                breed            = pet?.breed ?? ""
                goalText         = "\(pet?.goalSteps ?? defaultGoal)"
                colorIndex       = pet?.accentColorIndex ?? 0
                emojiText        = pet?.customEmoji ?? ""
                hasOwnerContact  = pet?.hasOwnerContact ?? false
                ownerNameText    = pet?.ownerName ?? ""
                ownerPhoneText   = pet?.ownerPhone ?? ""
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
        updated.customEmoji  = emojiText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String(emojiText.trimmingCharacters(in: .whitespaces).prefix(2))
        updated.ownerName    = hasOwnerContact && !ownerNameText.trimmingCharacters(in: .whitespaces).isEmpty ? ownerNameText.trimmingCharacters(in: .whitespaces) : nil
        updated.ownerPhone   = hasOwnerContact && !ownerPhoneText.trimmingCharacters(in: .whitespaces).isEmpty ? ownerPhoneText.trimmingCharacters(in: .whitespaces) : nil
        if pet == nil { updated.isActiveOnWalk = true }
        onSave(updated)
        dismiss()
    }
}
