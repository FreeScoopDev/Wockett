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
                    VStack(spacing: 24) {
                        ZStack {
                            Circle()
                                .stroke(pet.accentColor.opacity(0.2), lineWidth: 18)
                                .frame(width: 160, height: 160)
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(pet.accentColor, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 160, height: 160)
                                .animation(.easeInOut(duration: 0.7), value: progress)
                            VStack(spacing: 4) {
                                Text(pet.displayEmoji).font(.system(size: 40))
                                Text("\(Int(progress * 100))%")
                                    .font(.system(size: 22, weight: .bold, design: .rounded))
                                    .foregroundColor(.earthCream)
                            }
                        }
                        .padding(.top, 8)

                        Text(pet.name)
                            .font(.title2.bold()).foregroundColor(.earthCream)
                        if let breed = pet.breed {
                            Text(breed).font(.subheadline).foregroundColor(.earthMuted)
                        }

                        HStack(spacing: 12) {
                            detailTile(value: todaySteps.formatted(), label: "Steps Today", icon: "figure.walk", color: pet.accentColor)
                            detailTile(value: pet.goalSteps.formatted(), label: "Daily Goal", icon: "flag.fill", color: .earthMuted)
                        }
                        .padding(.horizontal)

                        HStack(spacing: 12) {
                            detailTile(value: "\(totalWalks)", label: "Total Walks", icon: "clock.arrow.circlepath", color: .earthGreen)
                            detailTile(value: MKDistanceFormatter.abbreviated.string(fromDistance: totalDist), label: "Total Distance", icon: "ruler", color: .earthGreen)
                        }
                        .padding(.horizontal)

                        HStack(spacing: 12) {
                            detailTile(value: streak > 0 ? "\(streak)d" : "—", label: "Walk Streak", icon: "flame.fill", color: streak > 0 ? .earthOrange : .earthMuted)
                            detailTile(value: "\(recentSessions.count)", label: "Walks This Week", icon: "calendar", color: .earthMuted)
                        }
                        .padding(.horizontal)

                        if !recentSessions.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Last 7 Days")
                                    .font(.headline).foregroundColor(.earthCream)
                                    .padding(.horizontal)

                                HStack(spacing: 12) {
                                    detailTile(value: weeklySteps.formatted(), label: "Steps", icon: "figure.walk", color: pet.accentColor)
                                    detailTile(value: MKDistanceFormatter.abbreviated.string(fromDistance: weeklyDist), label: "Distance", icon: "ruler", color: pet.accentColor)
                                }
                                .padding(.horizontal)

                                ForEach(recentSessions.prefix(5)) { session in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(session.routeName).font(.subheadline).foregroundColor(.earthCream).lineLimit(1)
                                            Text(session.formattedDate).font(.caption).foregroundColor(.earthMuted)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(session.distanceText).font(.subheadline.bold()).foregroundColor(pet.accentColor)
                                            Text("\(session.estimatedSteps.formatted()) steps").font(.caption).foregroundColor(.earthMuted)
                                        }
                                    }
                                    .padding(.horizontal).padding(.vertical, 8)
                                    .background(Color.earthCard).cornerRadius(10)
                                    .padding(.horizontal)
                                }
                            }
                        }

                        Spacer(minLength: 32)
                    }
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

    private func detailTile(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(color).font(.title3)
            Text(value).font(.headline.bold()).foregroundColor(.earthCream)
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .background(Color.earthCard).cornerRadius(14)
    }
}
