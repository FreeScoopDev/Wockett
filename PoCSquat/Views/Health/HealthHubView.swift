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
    @State private var pushInsights      = false
    private var healthExtras = HealthExtrasAccess.shared

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                    switch healthExtras.state {
                    case .ready:    RecoveryCard()
                    case .needsAsk: HealthExtrasCard()
                    case .checking: EmptyView()
                    }
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
                    if healthExtras.state == .ready { GaitHealthSection() }
                    HealthFunStatsCard(sessions: historyStore.sessions)
                    insightsCard
                    activityHistoryCard
                    HealthDisclaimer()
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
        .task { await healthExtras.refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("health.root")
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(isPresented: $pushWalkHistory) {
            WalkHistoryView(store: historyStore)
        }
        .navigationDestination(isPresented: $pushInsights) {
            InsightsView()
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

    /// Health → Insights: this week's distance and activity count on the card.
    private var insightsCard: some View {
        Button { pushInsights = true } label: {
            HStack(spacing: 12) {
                WktIconBadge(symbol: .insights, tint: .earthGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Insights")
                        .font(.wktRowTitle)
                        .foregroundColor(.earthCream)
                    let week = InsightsSummary.comparison(historyStore.sessions, period: .week,
                                                          now: Date(), calendar: .current).current
                    Text(week.sessions == 0 ? "Weekly and monthly trends"
                         : "This week: \(InsightsText.distance(week.distanceMeters)) · \(week.sessions) \(week.sessions == 1 ? "activity" : "activities")")
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
        .accessibilityIdentifier("health.insights")
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

/// The fun-stat facts, from recorded sessions only. Until 2026-10-27 the card
/// added today's Health steps (which already hold a walk recorded today, so
/// that walk counted twice), gave rides distance / 0.762 m steps, and kept
/// sessions flagged as possible driving. Now: the same sessions Insights
/// counts; distance spans every activity, rides included; steps are
/// `ActivitySummaryContent.humanSteps`, so rides add none.
nonisolated enum FunStats {
    nonisolated struct Fact: Equatable {
        let emoji: String; let headline: String; let detail: String
    }

    /// Total distance in km and human steps of the sessions that count.
    nonisolated static func totals(_ sessions: [WalkSession]) -> (km: Double, steps: Int) {
        let counted = InsightsSummary.counted(sessions)
        let km = counted.reduce(0.0) { $0 + $1.totalDistance } / 1000
        let steps = counted.reduce(0) { $0 + ActivitySummaryContent.humanSteps($1) }
        return (km, steps)
    }

    /// Every fact the totals earn, in the card's order.
    nonisolated static func allFacts(from sessions: [WalkSession]) -> [Fact] {
        let (totalKm, totalSteps) = totals(sessions)
        var result: [Fact] = []
        let bridges = Int(totalKm / 2.73)
        if bridges >= 1 {
            result.append(Fact(emoji: "🌉",
                headline: "\(bridges) Golden Gate crossing\(bridges == 1 ? "" : "s")",
                detail: "Recorded distance, all activities"))
        }
        let marathons = Int(totalKm / 42.195)
        if marathons >= 1 {
            result.append(Fact(emoji: "🏅",
                headline: "Distance equal to \(marathons) marathon\(marathons == 1 ? "" : "s")",
                detail: "Recorded distance, all activities"))
        }
        let esbClimbs = totalSteps / 1_576
        if esbClimbs >= 1 {
            result.append(Fact(emoji: "🏙️",
                headline: "Step count equal to \(esbClimbs) Empire State climb\(esbClimbs == 1 ? "" : "s")",
                detail: "Estimated steps from walks and runs · 1,576 stairs per climb"))
        }
        let earthPct = (totalKm / 40_075) * 100
        if earthPct >= 0.01 {
            result.append(Fact(emoji: "🌍",
                headline: String(format: "%.2f%% around Earth", earthPct),
                detail: "Recorded distance, all activities · 40,075 km circumference"))
        }
        return result
    }

    /// What the card shows: the first two facts.
    nonisolated static func facts(from sessions: [WalkSession]) -> [Fact] {
        Array(allFacts(from: sessions).prefix(2))
    }
}

struct HealthFunStatsCard: View {
    let sessions: [WalkSession]

    private var facts: [FunStats.Fact] { FunStats.facts(from: sessions) }

    var body: some View {
        if facts.isEmpty { EmptyView() } else {
            WktSection(title: "Your journey in perspective") {
                HStack(alignment: .top, spacing: WktSpacing.betweenCards) {
                    ForEach(facts, id: \.headline) { fact in
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
