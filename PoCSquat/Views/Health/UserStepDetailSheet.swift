import SwiftUI
import MapKit

struct UserStepDetailSheet: View {
    @ObservedObject var stepManager: StepManager
    @ObservedObject var historyStore: WalkHistoryStore
    @Environment(\.dismiss) private var dismiss

    private var recentSessions: [WalkSession] {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return historyStore.sessions.filter { $0.date >= cutoff }
    }

    private var weeklySteps: Int { recentSessions.reduce(0) { $0 + $1.estimatedSteps } }
    private var weeklyDistance: Double { recentSessions.reduce(0) { $0 + $1.totalDistance } }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        ZStack {
                            Circle()
                                .stroke(Color.earthMuted.opacity(0.15), lineWidth: 18)
                                .frame(width: 160, height: 160)
                            Circle()
                                .trim(from: 0, to: stepManager.progress)
                                .stroke(
                                    LinearGradient(colors: [.earthGreen, .earthOrange], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    style: StrokeStyle(lineWidth: 18, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                                .frame(width: 160, height: 160)
                                .animation(.easeInOut(duration: 0.6), value: stepManager.progress)
                            VStack(spacing: 2) {
                                Text("\(Int(stepManager.progress * 100))%")
                                    .font(.wktDisplay(32))
                                    .foregroundColor(.earthCream)
                                Text("of goal")
                                    .font(.wktBody(12)).foregroundColor(.earthMuted)
                            }
                        }
                        .padding(.top, 8)

                        HStack(spacing: 12) {
                            detailTile(value: stepManager.todaySteps.formatted(), label: "Steps Today", icon: .steps, color: .earthGreen)
                            detailTile(value: stepManager.currentGoal.formatted(), label: "Daily Goal", icon: .finish, filled: true, color: .earthOrange, subtitle: {
                                let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
                                return "≈ \(f.string(fromDistance: Double(stepManager.currentGoal) * 0.762))"
                            }())
                        }
                        .padding(.horizontal)

                        HStack(spacing: 12) {
                            detailTile(value: stepManager.remainingSteps.formatted(), label: "Remaining", icon: .arrowRightCircle, color: .earthMuted)
                            let f = MKDistanceFormatter(); let _ = f.unitStyle = .abbreviated
                            detailTile(value: f.string(fromDistance: stepManager.remainingMeters), label: "Distance Left", icon: .distance, color: .earthMuted)
                        }
                        .padding(.horizontal)

                        if !recentSessions.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                WktSectionHeader(title: "Last 7 Days")
                                    .padding(.horizontal)

                                HStack(spacing: 12) {
                                    detailTile(value: weeklySteps.formatted(), label: "Steps", icon: .steps, color: .earthGreen)
                                    let df = MKDistanceFormatter(); let _ = df.unitStyle = .abbreviated
                                    detailTile(value: df.string(fromDistance: weeklyDistance), label: "Distance", icon: .distance, color: .earthGreen)
                                }
                                .padding(.horizontal)

                                ForEach(recentSessions.prefix(5)) { session in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(session.routeName).font(.wktBody(15)).foregroundColor(.earthCream).lineLimit(1)
                                            Text(session.formattedDate).font(.wktBody(12)).foregroundColor(.earthMuted)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(session.distanceText).font(.wktHeading(15)).foregroundColor(.earthGreen)
                                            Text("\(session.estimatedSteps.formatted()) steps").font(.wktBody(12)).foregroundColor(.earthMuted)
                                        }
                                    }
                                    .wktCard(padding: 12)
                                    .padding(.horizontal)
                                }
                            }
                        }
                        Spacer(minLength: 32)
                    }
                }
            }
            .navigationTitle("Your Progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.earthGreen)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func detailTile(
        value: String, label: String, icon: WktSymbol, filled: Bool = false, color: Color, subtitle: String? = nil
    ) -> some View {
        VStack(spacing: 6) {
            Image(wkt: icon).wktIcon(.row, tint: color, filled: filled)
            Text(value).font(.wktHeading(17)).foregroundColor(.earthCream)
            if let subtitle {
                Text(subtitle).font(.wktBody(11)).foregroundColor(.earthMuted)
            }
            Text(label).font(.wktBody(12)).foregroundColor(.earthMuted)
        }
        // Centred tile: the full-width frame keeps it centred inside wktCard's leading frame.
        .frame(maxWidth: .infinity)
        .wktCard(padding: 18)
    }
}
