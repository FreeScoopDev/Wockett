import SwiftUI
import SwiftData

// MARK: - Health Hub View

struct HealthHubView: View {
    @EnvironmentObject private var stepManager:  StepManager
    @EnvironmentObject private var historyStore: WalkHistoryStore

    @State private var calendarWeekOffset: Int = 0
    @State private var selectedCalendarDay: CalendarDay? = nil
    @State private var showMonthCalendar = false
    @State private var pushWalkHistory   = false

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    RecoveryCard()
                    WeeklyCalendarView(
                        days: stepManager.weeklyCalendar,
                        weekOffset: calendarWeekOffset,
                        stepManager: stepManager,
                        onDayTap: { selectedCalendarDay = $0 },
                        onWeekChange: { delta in
                            let newOffset = (calendarWeekOffset + delta).clamped(to: -52...52)
                            guard newOffset != calendarWeekOffset else { return }
                            calendarWeekOffset = newOffset
                            Task {
                                await stepManager.refreshWeeklyCalendar(
                                    sessions: historyStore.sessions, weekOffset: newOffset)
                            }
                        },
                        onCalendarTap: { showMonthCalendar = true }
                    )
                    GaitHealthSection()
                    HealthFunStatsCard(sessions: historyStore.sessions, todaySteps: stepManager.todaySteps)
                        .padding(.horizontal)
                    activityHistoryCard
                }
                .padding(.bottom, 40)
            }
            .refreshable {
                await stepManager.refreshWeeklyCalendar(
                    sessions: historyStore.sessions, weekOffset: calendarWeekOffset)
            }
        }
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(isPresented: $pushWalkHistory) {
            WalkHistoryView(store: historyStore)
        }
        .sheet(item: $selectedCalendarDay) { day in
            DayDetailSheet(day: day, sessions: historyStore.sessions)
        }
        .sheet(isPresented: $showMonthCalendar) {
            MonthCalendarView(stepManager: stepManager, sessions: historyStore.sessions)
        }
        .onAppear {
            if calendarWeekOffset != 0 {
                calendarWeekOffset = 0
            }
            Task {
                await stepManager.refreshWeeklyCalendar(
                    sessions: historyStore.sessions, weekOffset: 0)
            }
        }
    }

    private var activityHistoryCard: some View {
        Button { pushWalkHistory = true } label: {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.earthOrange.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.earthOrange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Activity History")
                        .font(.wktHeading(17))
                        .foregroundColor(.earthCream)
                    let count = historyStore.sessions.count
                    Text(count == 0 ? "No activities yet" : "\(count) activit\(count == 1 ? "y" : "ies")")
                        .font(.wktBody(13))
                        .foregroundColor(.earthMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.earthMuted.opacity(0.5))
            }
            .padding(16)
            .background(Color.earthCard)
            .cornerRadius(18)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.97))
        .padding(.horizontal)
    }
}

// MARK: - Fun Stats Card

struct HealthFunStatsCard: View {
    let sessions:   [WalkSession]
    let todaySteps: Int

    private var totalKm:    Double { sessions.reduce(0.0) { $0 + $1.totalDistance } / 1000 }
    private var totalSteps: Int    { sessions.reduce(0)   { $0 + $1.estimatedSteps } + todaySteps }

    private struct Fact: Identifiable {
        let id = UUID()
        let emoji: String; let headline: String; let detail: String
    }

    private var facts: [Fact] {
        var result: [Fact] = []
        let bridges = Int(totalKm / 2.73)
        if bridges >= 1 {
            result.append(Fact(emoji: "🌉",
                headline: "\(bridges) Golden Gate crossing\(bridges == 1 ? "" : "s")",
                detail: "Total distance covered"))
        }
        let marathons = Int(totalKm / 42.195)
        if marathons >= 1 {
            result.append(Fact(emoji: "🏅",
                headline: "\(marathons) marathon\(marathons == 1 ? "" : "s") completed",
                detail: "Based on total distance"))
        }
        let esbClimbs = totalSteps / 1_576
        if esbClimbs >= 1 {
            result.append(Fact(emoji: "🏙️",
                headline: "\(esbClimbs)× up the Empire State Building",
                detail: "1,576 steps per climb"))
        }
        let earthPct = (totalKm / 40_075) * 100
        if earthPct >= 0.01 {
            result.append(Fact(emoji: "🌍",
                headline: String(format: "%.2f%% around Earth", earthPct),
                detail: "40,075 km circumference"))
        }
        return Array(result.prefix(2))
    }

    var body: some View {
        if facts.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your Journey in Perspective")
                    .font(.caption.bold())
                    .foregroundColor(.earthMuted)
                    .textCase(.uppercase)
                HStack(spacing: 10) {
                    ForEach(facts) { fact in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fact.emoji).font(.title2)
                            Text(fact.headline)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.earthCream)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(fact.detail)
                                .font(.system(size: 10))
                                .foregroundColor(.earthMuted)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.earthCard)
                        .cornerRadius(14)
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Health Hub") {
    NavigationStack {
        HealthHubView()
    }
    .environmentObject(StepManager())
    .environmentObject(WalkHistoryStore())
    .environmentObject(PetStore(context: AppModelContainer.shared.mainContext))
}
