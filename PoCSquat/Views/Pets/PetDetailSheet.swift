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
    private var recentSessions: [WalkSession] { petStore.recentSessions(for: pet, in: historyStore.sessions) }

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
                            HStack(spacing: WktSpacing.betweenCards) {
                                WktIconStatTile(value: todaySteps.formatted(), label: "Steps today",
                                                symbol: .steps, tint: pet.accentColor)
                                WktIconStatTile(value: pet.goalSteps.formatted(), label: "Daily goal",
                                                symbol: .finish, tint: .earthMuted)
                            }
                            HStack(spacing: WktSpacing.betweenCards) {
                                WktIconStatTile(value: "\(totalWalks)", label: "Total walks", symbol: .history)
                                WktIconStatTile(value: MKDistanceFormatter.abbreviated.string(fromDistance: totalDist),
                                                label: "Total distance", symbol: .distance)
                            }
                            HStack(spacing: WktSpacing.betweenCards) {
                                WktIconStatTile(value: streak > 0 ? "\(streak)d" : "—", label: "Walk streak",
                                                symbol: .calories, tint: streak > 0 ? .earthOrange : .earthMuted)
                                WktIconStatTile(value: "\(recentSessions.count)", label: "Walks this week",
                                                symbol: .calendar, tint: .earthMuted)
                            }
                        }

                        if !recentSessions.isEmpty {
                            WktSection(title: "Last 7 days") {
                                HStack(spacing: WktSpacing.betweenCards) {
                                    WktIconStatTile(value: weeklySteps.formatted(), label: "Steps",
                                                    symbol: .steps, tint: pet.accentColor)
                                    WktIconStatTile(value: MKDistanceFormatter.abbreviated.string(fromDistance: weeklyDist),
                                                    label: "Distance", symbol: .distance, tint: pet.accentColor)
                                }
                                VStack(spacing: 0) {
                                    ForEach(Array(recentSessions.prefix(5).enumerated()), id: \.element.id) { index, session in
                                        if index > 0 { WktDivider() }
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(session.routeName).font(.wktRowTitle).foregroundColor(.earthCream).lineLimit(1)
                                                Text(session.formattedDate).font(.wktLabel).foregroundColor(.earthMuted)
                                            }
                                            Spacer()
                                            VStack(alignment: .trailing, spacing: 2) {
                                                Text(session.distanceText).font(.wktRowTitle).foregroundColor(pet.accentColor)
                                                Text("\(session.estimatedSteps.formatted()) steps").font(.wktLabel).foregroundColor(.earthMuted)
                                            }
                                        }
                                        .padding(.vertical, 10)
                                        .accessibilityElement(children: .combine)
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
}
