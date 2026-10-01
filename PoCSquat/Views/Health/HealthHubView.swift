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
                VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
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
                    activityHistoryCard
                }
                .padding(.horizontal, WktSpacing.screen)
                .padding(.top, 8)
                .padding(.bottom, WktSpacing.betweenSections)
            }
            .refreshable {
                await stepManager.refreshWeeklyCalendar(
                    sessions: historyStore.sessions, weekOffset: calendarWeekOffset)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("health.root")
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
            HStack(spacing: 12) {
                WktIconBadge(symbol: .history, tint: .earthOrange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity History")
                        .font(.wktRowTitle)
                        .foregroundColor(.earthCream)
                    let count = historyStore.sessions.count
                    Text(count == 0 ? "No activities yet" : "\(count) activit\(count == 1 ? "y" : "ies")")
                        .font(.wktLabel)
                        .foregroundColor(.earthMuted)
                }
                Spacer()
                Image(wkt: .chevronRight)
                    .wktIcon(.inline, tint: .earthMuted)
                    .accessibilityHidden(true)
            }
            .wktCard()
        }
        .buttonStyle(BounceButtonStyle(scale: 0.97))
        .accessibilityElement(children: .combine)
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
            WktSection(title: "Your journey in perspective") {
                HStack(alignment: .top, spacing: WktSpacing.betweenCards) {
                    ForEach(facts) { fact in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(fact.emoji)
                                .font(.title2) // the fact's own emoji (data)
                                .accessibilityHidden(true)
                            Text(fact.headline)
                                .font(.wktRowTitle)
                                .foregroundColor(.earthCream)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(fact.detail)
                                .font(.wktLabel)
                                .foregroundColor(.earthMuted)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                        .wktCard()
                        .accessibilityElement(children: .combine)
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
