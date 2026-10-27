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
    // Static so views and tests (the Community hub's crew card) share the one rule.
    nonisolated static func participated(_ petID: UUID, in session: WalkSession) -> Bool {
        session.petDistances.isEmpty
            ? session.activePetIds.contains(petID)
            : (session.petDistances[petID] ?? 0) > 0
    }

    nonisolated static func walkedMeters(_ petID: UUID, in session: WalkSession) -> Double {
        if session.petDistances.isEmpty {
            return session.activePetIds.contains(petID) ? session.totalDistance : 0
        }
        return session.petDistances[petID] ?? 0
    }

    private func petParticipated(_ pet: PetProfile, in session: WalkSession) -> Bool {
        Self.participated(pet.id, in: session)
    }

    private func petWalkedMeters(_ pet: PetProfile, in session: WalkSession) -> Double {
        Self.walkedMeters(pet.id, in: session)
    }

    func todaySteps(for pet: PetProfile, in sessions: [WalkSession]) -> Int {
        let cal = Calendar.current
        return sessions
            .filter { cal.isDateInToday($0.date) }
            .reduce(0) { $0 + PetOutingRow.estimatedSteps(meters: petWalkedMeters(pet, in: $1)) }
    }

    func totalWalks(for pet: PetProfile, in sessions: [WalkSession]) -> Int {
        sessions.filter { petParticipated(pet, in: $0) }.count
    }

    func totalDistance(for pet: PetProfile, in sessions: [WalkSession]) -> Double {
        sessions.reduce(0) { $0 + petWalkedMeters(pet, in: $1) }
    }

    // The pet detail sheet shows two different periods, each named for what
    // it is (2026-10-27): the "Walks this week" tile is the calendar week, as
    // Insights counts it; the "Last 7 days" section (its steps, distance and
    // list) is today plus the six calendar days before. Both come from
    // `InsightsSummary`, so they never use `now` minus 168 hours again.

    /// The pet's walks that started inside `window` and not after `now`,
    /// newest first.
    nonisolated static func sessions(_ petID: UUID, in sessions: [WalkSession], during window: DateInterval,
                                     now: Date) -> [WalkSession] {
        sessions
            .filter { InsightsSummary.counts($0.date, in: window, now: now) && participated(petID, in: $0) }
            .sorted { $0.date > $1.date }
    }

    /// The "Last 7 days" list's window: today plus the six calendar days before.
    nonisolated static func lastSevenDays(_ petID: UUID, in sessions: [WalkSession],
                                          now: Date, calendar: Calendar) -> [WalkSession] {
        Self.sessions(petID, in: sessions, during: InsightsSummary.last7Days(now: now, calendar: calendar), now: now)
    }

    /// The "Walks this week" tile's window: the locale's calendar week so far.
    nonisolated static func thisWeek(_ petID: UUID, in sessions: [WalkSession],
                                     now: Date, calendar: Calendar) -> [WalkSession] {
        Self.sessions(petID, in: sessions,
                      during: InsightsSummary.calendarWeek(containing: now, calendar: calendar), now: now)
    }

    /// The "Last 7 days" section's distance for one pet.
    nonisolated static func lastSevenDaysMeters(_ petID: UUID, in sessions: [WalkSession],
                                                now: Date, calendar: Calendar) -> Double {
        lastSevenDays(petID, in: sessions, now: now, calendar: calendar).reduce(0) { $0 + walkedMeters(petID, in: $1) }
    }

    func weeklySteps(for pet: PetProfile, in sessions: [WalkSession],
                     now: Date = Date(), calendar: Calendar = .current) -> Int {
        PetOutingRow.lastSevenDays(pet.id, in: sessions, now: now, calendar: calendar)
            .reduce(0) { $0 + $1.estimatedSteps }
    }

    func weeklyDistance(for pet: PetProfile, in sessions: [WalkSession],
                        now: Date = Date(), calendar: Calendar = .current) -> Double {
        Self.lastSevenDaysMeters(pet.id, in: sessions, now: now, calendar: calendar)
    }

    /// The "Walks this week" tile: the locale's calendar week so far.
    func sessionsThisWeek(for pet: PetProfile, in sessions: [WalkSession],
                          now: Date = Date(), calendar: Calendar = .current) -> [WalkSession] {
        Self.thisWeek(pet.id, in: sessions, now: now, calendar: calendar)
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
        let notifications = NotificationService.shared
        notifications.cancel(.petNudge)
        guard notifications.isEnabled(.petNudge) else { return }

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
        let body = overduePets.count == 1
            ? "\(overduePets[0].name) hasn't been on a walk in a couple of days."
            : "Your pets haven't walked in a couple of days."
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
            repeats: false
        )
        await notifications.schedule(.petNudge, title: "\(names)\(extra) could use a walk! 🐾", body: body, trigger: trigger)
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
                    Image(wkt: .add).wktIcon(.inline, tint: .earthGreen)
                }
                .accessibilityLabel("Add pet")
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
                    .listRowSeparatorTint(Color.earthTrack)
            }
            Button { showAddPet = true } label: {
                Label { Text("Add a Pet") } icon: { Image(wkt: .addCircle).wktIcon(.row, tint: .earthGreen, filled: true) }
                    .font(.wktRowTitle)
                    .foregroundColor(.earthGreen)
                    .frame(minHeight: 44)
            }
            .listRowBackground(Color.earthCard)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        WktEmptyState(symbol: .pets, tint: .earthGreen, title: "No pets yet",
                      message: "Add a pet to track their walks alongside yours.",
                      actionTitle: "Add a Pet") { showAddPet = true }
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
            // displayEmoji, not emoji: a custom emoji showed everywhere but here.
            Text(pet.displayEmoji) // the pet's own emoji (data)
                .font(.system(size: 24))
                .frame(width: 44, height: 44)
                .background(pet.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(pet.name).font(.wktRowTitle).foregroundColor(.earthCream)
                    if let breed = pet.breed {
                        Text("· \(breed)").font(.wktLabel).foregroundColor(.earthMuted)
                    }
                }
                HStack(spacing: 10) {
                    Label { Text("\(totalWalks) walks") } icon: { Image(wkt: .walk).wktIcon(.inline, tint: .earthMuted) }
                    Label { Text(totalDistText) } icon: { Image(wkt: .distance).wktIcon(.inline, tint: .earthMuted) }
                }
                .font(.wktLabel).foregroundColor(.earthMuted)
                Text(PetCreditText.goal(pet.goalSteps))
                    .font(.wktLabel).foregroundColor(pet.accentColor)
                // The switch's state in words, not only its colour.
                Text(PetCreditText.status(isActive: pet.isActiveOnWalk))
                    .font(.wktLabel)
                    .foregroundColor(pet.isActiveOnWalk ? .earthGreen : .earthMuted)
            }

            Spacer()

            // A real label, hidden on screen: VoiceOver found a switch with no
            // name when this was Toggle("", …) (2026-10-27).
            Toggle(isOn: Binding(
                get: { pet.isActiveOnWalk },
                set: { petStore.setActive(pet.id, active: $0) }
            )) {
                Text(PetCreditText.switchLabel(name: pet.name))
            }
            .labelsHidden()
            .tint(pet.accentColor)
            .accessibilityHint(PetCreditText.switchHint)
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
                    VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                        Text(emojiText.isEmpty ? previewEmoji : emojiText)
                            .font(.system(size: 64)) // the pet's emoji (data)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                            .accessibilityHidden(true)

                        field(label: "Name") {
                            TextField("Buddy, Luna, Max…", text: $name).foregroundColor(.earthCream)
                        }

                        WktSection(title: "Type") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(speciesOptions, id: \.self) { s in
                                        WktChoiceChip(title: s, selected: species == s) { species = s }
                                    }
                                }
                            }
                        }

                        field(label: "Breed (optional)") {
                            TextField("Golden Retriever, Mixed…", text: $breed).foregroundColor(.earthCream)
                        }

                        if breed.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text("Enter a breed to get a step goal suggestion. For mixed breeds, use the dominant breed (e.g. 'Labrador').")
                                .font(.wktLabel)
                                .foregroundColor(.earthMuted)
                        } else if suggestedGoal == nil {
                            Text("No suggestion for this breed — try a common name like 'Labrador', 'Poodle', or 'Golden Retriever'.")
                                .font(.wktLabel)
                                .foregroundColor(.earthMuted)
                        }

                        WktSection(title: "Custom emoji (optional)") {
                            HStack(spacing: 10) {
                                TextField("Tap to change…", text: $emojiText)
                                    .font(.wktBodyText)
                                    .foregroundColor(.earthCream)
                                    .padding(.horizontal, WktSpacing.cardPadding)
                                    .frame(minHeight: 52)
                                    .wktCardBackground()
                                if !emojiText.isEmpty {
                                    Button { emojiText = "" } label: {
                                        Image(wkt: .close).wktIcon(.inline, tint: .earthMuted, filled: true)
                                    }
                                    .accessibilityLabel("Clear emoji")
                                }
                            }
                        }

                        field(label: "Daily step goal") {
                            TextField("10000", text: $goalText).keyboardType(.numberPad).foregroundColor(.earthCream)
                        }

                        if let suggested = suggestedGoal, Int(goalText) != suggested {
                            Button { goalText = "\(suggested)" } label: {
                                Label {
                                    Text("A starting point for this breed: \(suggested.formatted()) steps. Change it to suit your pet; it isn't a health target.")
                                } icon: {
                                    Image(wkt: .tip).wktIcon(.inline, tint: .earthOrange, filled: true)
                                }
                                    .font(.wktLabel)
                                    .foregroundColor(.earthOrange)
                                    .frame(minHeight: 44)
                            }
                        }

                        WktSection(title: "Color") {
                            HStack(spacing: 12) {
                                ForEach(0..<PetProfile.accentColors.count, id: \.self) { i in
                                    Button { colorIndex = i } label: {
                                        ZStack {
                                            Circle().fill(PetProfile.accentColors[i]).frame(width: 32, height: 32)
                                            if colorIndex == i {
                                                Image(wkt: .check).wktIcon(.inline, tint: .white, onFill: true)
                                            }
                                        }
                                        .overlay(Circle().stroke(colorIndex == i ? Color.white.opacity(0.8) : Color.clear, lineWidth: 2))
                                    }
                                    .accessibilityLabel("Color option \(i + 1)")
                                    .accessibilityAddTraits(colorIndex == i ? .isSelected : [])
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $hasOwnerContact.animation()) {
                                Label {
                                    Text("This pet has an owner to notify")
                                } icon: {
                                    Image(wkt: .person).wktIcon(.inline, tint: .earthCream, filled: true)
                                }
                                .font(.wktRowTitle)
                                .foregroundColor(.earthCream)
                            }
                            .tint(.earthGreenFill)
                            .wktCard(padding: 14)

                            if hasOwnerContact {
                                field(label: "Owner name") {
                                    TextField("Jane Smith", text: $ownerNameText).foregroundColor(.earthCream)
                                }
                                field(label: "Owner phone") {
                                    TextField("+1 555 000 0000", text: $ownerPhoneText)
                                        .keyboardType(.phonePad)
                                        .foregroundColor(.earthCream)
                                }
                                Text("Used to quickly message the owner after walks. Stored only on this device.")
                                    .font(.wktLabel)
                                    .foregroundColor(.earthMuted)
                                    .padding(.horizontal, 4)
                            }
                        }

                        if onDelete != nil {
                            Button(role: .destructive) { onDelete?(); dismiss() } label: {
                                Text("Remove \(name.isEmpty ? "Pet" : name)")
                                    .font(.wktBodyText).foregroundColor(.red)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                        }
                    }
                    .padding(.horizontal, WktSpacing.screen)
                    .padding(.vertical, WktSpacing.betweenSections)
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

    /// A text field with its heading above it, as New Challenge's form.
    private func field<C: View>(label: String, @ViewBuilder content: @escaping () -> C) -> some View {
        WktSection(title: label) {
            content()
                .font(.wktBodyText)
                .padding(.horizontal, WktSpacing.cardPadding)
                .frame(minHeight: 52)
                .wktCardBackground()
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
