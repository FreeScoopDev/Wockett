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

    private func distance(_ meters: Double) -> String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: meters)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                        WktGoalRing(progress: stepManager.progress, lineWidth: 16) {
                            VStack(spacing: 2) {
                                Text(WktPercent.text(stepManager.progress))
                                    .font(.wktMetric)
                                    .foregroundColor(.earthCream)
                                Text("of goal")
                                    .font(.wktLabel).foregroundColor(.earthMuted)
                            }
                        }
                        .frame(width: 176, height: 176)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .accessibilityElement(children: .combine)

                        WktSection(title: "Today") {
                            WktStatGrid(items: [
                                .init(label: "Steps today", value: stepManager.todaySteps.formatted(), note: "so far"),
                                .init(label: "Daily goal", value: stepManager.currentGoal.formatted(),
                                      note: "≈ \(distance(Double(stepManager.currentGoal) * 0.762))"),
                                .init(label: "Remaining", value: stepManager.remainingSteps.formatted(), note: "steps"),
                                .init(label: "Distance left", value: distance(stepManager.remainingMeters), note: "to your goal")
                            ])
                        }

                        if !recentSessions.isEmpty {
                            WktSection(title: "Last 7 days") {
                                WktStatGrid(items: [
                                    .init(label: "Steps", value: weeklySteps.formatted(), note: "from activities"),
                                    .init(label: "Distance", value: distance(weeklyDistance), note: "from activities")
                                ])
                                VStack(spacing: 0) {
                                    ForEach(Array(recentSessions.prefix(5).enumerated()), id: \.element.id) { index, session in
                                        if index > 0 { WktDivider() }
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(session.routeName)
                                                    .font(.wktRowTitle).foregroundColor(.earthCream).lineLimit(1)
                                                Text(session.formattedDate)
                                                    .font(.wktLabel).foregroundColor(.earthMuted)
                                            }
                                            Spacer()
                                            VStack(alignment: .trailing, spacing: 2) {
                                                Text(session.distanceText)
                                                    .font(.wktRowTitle).foregroundColor(.earthGreen)
                                                Text("\(session.estimatedSteps.formatted()) steps")
                                                    .font(.wktLabel).foregroundColor(.earthMuted)
                                            }
                                        }
                                        .padding(.vertical, 10)
                                        .accessibilityElement(children: .combine)
                                    }
                                }
                                .wktCard(padding: 14)
                            }
                        }
                    }
                    .padding(.horizontal, WktSpacing.screen)
                    .padding(.bottom, WktSpacing.betweenSections)
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
}
