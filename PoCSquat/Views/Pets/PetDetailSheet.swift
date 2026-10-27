import SwiftUI
import MapKit

struct PetDetailSheet: View {
    let pet: PetProfile
    @ObservedObject var petStore: PetStore
    @ObservedObject var historyStore: WalkHistoryStore
    let onEdit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showEditor = false

    private var todaySteps: Int { petStore.todaySteps(for: pet, in: historyStore.sessions) }
    private var progress: Double { min(1.0, Double(todaySteps) / Double(max(1, pet.goalSteps))) }
    private var totalWalks: Int { petStore.totalWalks(for: pet, in: historyStore.sessions) }
    private var totalDist: Double { petStore.totalDistance(for: pet, in: historyStore.sessions) }
    private var streak: Int { petStore.walkStreak(for: pet, in: historyStore.sessions) }
    private var weeklySteps: Int { petStore.weeklySteps(for: pet, in: historyStore.sessions) }
    private var weeklyDist: Double { petStore.weeklyDistance(for: pet, in: historyStore.sessions) }
    /// Today plus the six calendar days before: the "Last 7 days" section,
    /// each row the pet's own credit, so the rows add up to `weeklyDist`.
    private var recentRows: [PetOutingRow] {
        PetOutingRow.lastSevenDays(pet.id, in: historyStore.sessions, now: Date(), calendar: .current)
    }
    /// The locale's calendar week, as Insights counts it: the "Walks this week" tile.
    private var walksThisWeek: Int { petStore.sessionsThisWeek(for: pet, in: historyStore.sessions).count }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                        VStack(spacing: 8) {
                            WktGoalRing(progress: progress, lineWidth: 16, tint: pet.accentColor) {
                                VStack(spacing: 4) {
                                    Text(pet.displayEmoji).font(.system(size: 40)) // the pet's own emoji (data)
                                    Text(WktPercent.text(progress))
                                        .font(.wktCardTitle)
                                        .foregroundColor(.earthCream)
                                }
                            }
                            .frame(width: 176, height: 176)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(pet.name), \(WktPercent.value(progress)) percent of today's goal")

                            Text(pet.name)
                                .font(.wktCardTitle).foregroundColor(.earthCream)
                            if let breed = pet.breed {
                                Text(breed).font(.wktBodyText).foregroundColor(.earthMuted)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                        VStack(spacing: WktSpacing.betweenCards) {
                            // Credited distance and walks lead; the step
                            // figures after them are estimates (2026-10-27).
                            HStack(spacing: WktSpacing.betweenCards) {
                                WktIconStatTile(value: "\(totalWalks)", label: "Total walks", symbol: .history)
                                WktIconStatTile(value: MKDistanceFormatter.abbreviated.string(fromDistance: totalDist),
                                                label: "Total distance", symbol: .distance)
                            }
                            HStack(spacing: WktSpacing.betweenCards) {
                                WktIconStatTile(value: todaySteps.formatted(), label: "Est. steps today",
                                                symbol: .steps, tint: pet.accentColor)
                                WktIconStatTile(value: pet.goalSteps.formatted(), label: "Daily goal (est. steps)",
                                                symbol: .finish, tint: .earthMuted)
                            }
                            HStack(spacing: WktSpacing.betweenCards) {
                                WktIconStatTile(value: streak > 0 ? "\(streak)d" : "—", label: "Walk streak",
                                                symbol: .calories, tint: streak > 0 ? .earthOrange : .earthMuted)
                                WktIconStatTile(value: "\(walksThisWeek)", label: "Walks this week",
                                                symbol: .calendar, tint: .earthMuted)
                            }
                            Text(PetCreditText.estimateCaption(name: pet.name))
                                .font(.wktLabel)
                                .foregroundColor(.earthMuted)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        let rows = recentRows
                        if !rows.isEmpty {
                            WktSection(title: "Last 7 days") {
                                HStack(spacing: WktSpacing.betweenCards) {
                                    WktIconStatTile(value: MKDistanceFormatter.abbreviated.string(fromDistance: weeklyDist),
                                                    label: "Distance", symbol: .distance, tint: pet.accentColor)
                                    WktIconStatTile(value: weeklySteps.formatted(), label: "Est. steps",
                                                    symbol: .steps, tint: pet.accentColor)
                                }
                                // Every outing in the window, not the first five:
                                // the rows add up to the Distance tile above.
                                VStack(spacing: 0) {
                                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                        if index > 0 { WktDivider() }
                                        outingRow(row)
                                    }
                                }
                                .wktCard(padding: 14)
                            }
                        }

                        Spacer(minLength: 32)
                    }
                    .padding(.horizontal, WktSpacing.screen)
                }
            }
            .navigationTitle(pet.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Edit") { showEditor = true }.foregroundColor(.earthGreen)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.earthMuted)
                }
            }
            .sheet(isPresented: $showEditor) {
                PetEditorSheet(pet: pet, defaultGoal: pet.goalSteps) { updated in
                    petStore.update(updated)
                    dismiss()
                } onDelete: {
                    petStore.remove(id: pet.id)
                    dismiss()
                }
            }
        }
        .presentationDetents([.large])
    }

    /// One outing: the pet's credited distance first, in its colour; an
    /// estimate of steps when the activity shows steps; the whole outing's
    /// distance when the pet was on only part of it.
    private func outingRow(_ row: PetOutingRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.session.routeName).font(.wktRowTitle).foregroundColor(.earthCream).lineLimit(1)
                Text(row.session.formattedDate).font(.wktLabel).foregroundColor(.earthMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(MKDistanceFormatter.abbreviated.string(fromDistance: row.creditedMeters))
                    .font(.wktRowTitle).foregroundColor(pet.accentColor)
                if ActivitySummaryContent.showsSteps(row.session) {
                    Text(PetCreditText.aboutSteps(row.estimatedSteps))
                        .font(.wktLabel).foregroundColor(.earthMuted)
                }
                if row.showsFullOuting {
                    Text("full outing \(MKDistanceFormatter.abbreviated.string(fromDistance: row.fullOutingMeters))")
                        .font(.wktLabel).foregroundColor(.earthMuted)
                }
            }
            .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
