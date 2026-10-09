import SwiftUI
import Charts
import MapKit

// MARK: - Insights screen
//
// Health → Insights. The numbers come from `InsightsSummary` (see there for
// what is free and what is Pro, and why the source is session history).
// Built from the shared pieces only: WktSegmentedPicker, WktMetricHero,
// WktStatGrid, WktSection, wktCard, WktProgressBar, WktEmptyState.

struct InsightsView: View {
    @EnvironmentObject private var historyStore: WalkHistoryStore
    @EnvironmentObject private var petStore: PetStore
    @ObservedObject private var pro = ProEntitlementStore.shared

    @State private var period: InsightsPeriod = .week
    @State private var showSupporter = false

    private let calendar = Calendar.current
    private var now: Date { Date() }
    private var sessions: [WalkSession] { historyStore.sessions }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            if InsightsSummary.counted(sessions).isEmpty {
                WktEmptyState(symbol: .insights, title: "No activities yet",
                              message: "Record a walk, run or ride and your weekly and monthly trends will appear here.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                        WktSegmentedPicker(selection: $period, options: [
                            .init(value: .week, title: "Week"),
                            .init(value: .month, title: "Month")
                        ])
                        .accessibilityIdentifier("insights.periodPicker")
                        summary
                        if pro.gate(.advancedAnalytics) {
                            depth
                        } else {
                            upsell
                        }
                    }
                    .padding(.horizontal, WktSpacing.screen)
                    .padding(.top, 8)
                    .padding(.bottom, WktSpacing.betweenSections)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("insights.root")
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(isPresented: $showSupporter) { TipJarView() }
    }

    // MARK: Free: this period

    private var comparison: (current: InsightsTotals, previous: InsightsTotals) {
        InsightsSummary.comparison(sessions, period: period, now: now, calendar: calendar)
    }

    @ViewBuilder private var summary: some View {
        let c = comparison
        WktMetricHero(badge: WktIconBadge(symbol: .insights, tint: .earthGreen),
                      value: InsightsText.distance(c.current.distanceMeters),
                      subtitle: "This \(period.noun) so far, from activities recorded in Wockett") {
            WktStatusChip(text: InsightsText.change(current: c.current.distanceMeters,
                                                    previous: c.previous.distanceMeters, period: period),
                          dot: changeColor(c))
        }
        dailyChart
        WktStatGrid(items: [
            .init(label: "Activities", value: "\(c.current.sessions)", note: InsightsText.versus(c.previous.sessions, period)),
            .init(label: "Active time", value: InsightsText.duration(c.current.duration),
                  note: "this time last \(period.noun) " + InsightsText.duration(c.previous.duration)),
            .init(label: "Steps", value: c.current.steps.formatted(), note: "estimated, from activities"),
            .init(label: "Active days", value: "\(c.current.activeDays)", note: InsightsText.versus(c.previous.activeDays, period))
        ])
    }

    private func changeColor(_ c: (current: InsightsTotals, previous: InsightsTotals)) -> Color {
        guard let change = InsightsSummary.change(current: c.current.distanceMeters,
                                                  previous: c.previous.distanceMeters) else { return .earthMuted }
        return change >= 0 ? .earthGreen : .earthOrange
    }

    private var dailyChart: some View {
        let buckets = InsightsSummary.dailyBuckets(sessions, period: period, now: now, calendar: calendar)
        return Chart(buckets) { b in
            BarMark(x: .value("Day", b.start, unit: .day),
                    y: .value("Distance", InsightsText.chartValue(b.distanceMeters)))
            .foregroundStyle(calendar.isDate(b.start, inSameDayAs: now) ? Color.earthGreen : Color.earthGreen.opacity(0.55))
            .cornerRadius(3)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: period == .week ? 1 : 7)) { _ in
                AxisValueLabel(format: period == .week ? .dateTime.weekday(.narrow) : .dateTime.month(.abbreviated).day())
                    .font(.wktBody(9))
                    .foregroundStyle(Color.earthMuted)
            }
        }
        .chartYAxis { InsightsText.yAxis }
        .frame(height: 140)
        .wktCard()
        .accessibilityLabel("Distance by day this \(period.noun)")
    }

    // MARK: Pro: depth

    @ViewBuilder private var depth: some View {
        let range = InsightsSummary.interval(period, containing: now, calendar: calendar)
        WktSection(title: period == .week ? "Last 8 weeks" : "Last 6 months") { trendChart }
        WktSection(title: "Activity mix") { activityMix(range) }
        WktSection(title: "Your pattern") { pattern(range) }
        let petTotals = InsightsSummary.pets(sessions, pets: petStore.pets, in: range)
        if !petTotals.isEmpty {
            WktSection(title: "Pets this \(period.noun)") { petsCard(petTotals) }
        }
    }

    private var trendChart: some View {
        let buckets = InsightsSummary.trend(sessions, period: period, now: now, calendar: calendar,
                                            count: period == .week ? 8 : 6)
        return Chart(buckets) { b in
            BarMark(x: .value("Period", b.start, unit: period == .week ? .weekOfYear : .month),
                    y: .value("Distance", InsightsText.chartValue(b.distanceMeters)))
            .foregroundStyle(b == buckets.last ? Color.earthGreen : Color.earthGreen.opacity(0.55))
            .cornerRadius(3)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: period == .week ? .weekOfYear : .month, count: period == .week ? 2 : 1)) { _ in
                AxisValueLabel(format: period == .week ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated))
                    .font(.wktBody(9))
                    .foregroundStyle(Color.earthMuted)
            }
        }
        .chartYAxis { InsightsText.yAxis }
        .frame(height: 140)
        .wktCard()
        .accessibilityLabel(period == .week ? "Distance per week, last 8 weeks" : "Distance per month, last 6 months")
    }

    private func activityMix(_ range: DateInterval) -> some View {
        let byMode = InsightsSummary.totals(sessions, in: range, calendar: calendar).distanceByActivity
        let total = byMode.values.reduce(0, +)
        let modes: [ActivityMode] = [.walking, .running, .cycling, .stationary].filter { (byMode[$0] ?? 0) > 0 }
        return VStack(alignment: .leading, spacing: 12) {
            if modes.isEmpty {
                Text("Nothing recorded this \(period.noun) yet.")
                    .font(.wktBodyText).foregroundColor(.earthMuted)
            }
            ForEach(modes, id: \.self) { mode in
                let meters = byMode[mode] ?? 0
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(wkt: mode.wktSymbol).wktIcon(.inline, tint: mode.tileColor)
                        Text(mode.sessionLabel).font(.wktRowTitle).foregroundColor(.earthCream)
                        Spacer()
                        Text(InsightsText.distance(meters)).font(.wktLabel).foregroundColor(.earthMuted)
                    }
                    WktProgressBar(value: total > 0 ? meters / total : 0, tint: mode.tileColor)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .wktCard()
    }

    private func pattern(_ range: DateInterval) -> some View {
        let averages = InsightsSummary.weekdayAverages(sessions, now: now, calendar: calendar)
        let busiest = averages.max { $0.value < $1.value }
        let times = InsightsSummary.timeOfDay(sessions, in: range, calendar: calendar)
        let usual = times.max { $0.value < $1.value }
        return VStack(alignment: .leading, spacing: 10) {
            patternRow(symbol: .calendar, title: "Busiest day",
                       detail: busiest.map { "\(calendar.weekdaySymbols[$0.key - 1]), \(InsightsText.distance($0.value)) on average" }
                           ?? "Not enough history yet")
            WktDivider()
            patternRow(symbol: .time, title: "Usual time",
                       detail: usual.map { "\($0.key.title), \($0.value) of \(times.values.reduce(0, +)) this \(period.noun)" }
                           ?? "Nothing recorded this \(period.noun) yet")
        }
        .wktCard()
    }

    private func patternRow(symbol: WktSymbol, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            WktIconBadge(symbol: symbol, tint: .earthGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.wktRowTitle).foregroundColor(.earthCream)
                Text(detail).font(.wktLabel).foregroundColor(.earthMuted)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func petsCard(_ totals: [InsightsPetTotals]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(totals.indices, id: \.self) { i in
                let t = totals[i]
                if i > 0 { WktDivider() }
                HStack(spacing: 12) {
                    WktIconBadge(symbol: .pets, tint: .earthOrange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.pet.name).font(.wktRowTitle).foregroundColor(.earthCream)
                        Text("\(t.sessions) \(t.sessions == 1 ? "walk" : "walks") · about \(t.estimatedSteps.formatted()) steps")
                            .font(.wktLabel).foregroundColor(.earthMuted)
                    }
                    Spacer(minLength: 0)
                    Text(InsightsText.distance(t.distanceMeters)).font(.wktLabel).foregroundColor(.earthCream)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .wktCard()
    }

    /// Shown only once Pro gating is on and the person is not Pro.
    private var upsell: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("More with Wockett Pro")
                .font(.wktRowTitle).foregroundColor(.earthCream)
            Text("Your longer trend, activity mix, weekly pattern and each pet's totals.")
                .font(.wktBodyText).foregroundColor(.earthMuted)
            WktPillButton(title: "See Pro") { showSupporter = true }
        }
        .wktCard()
        .accessibilityIdentifier("insights.upsell")
    }
}

// MARK: - Wording and units

enum InsightsText {
    static func distance(_ meters: Double) -> String {
        MKDistanceFormatter.abbreviated.string(fromDistance: meters)
    }

    /// Chart values in the person's unit, so the axis reads 2, 4, 6.
    static func chartValue(_ meters: Double) -> Double {
        Locale.current.measurementSystem == .us ? meters / 1_609.344 : meters / 1_000
    }

    static var unit: String { Locale.current.measurementSystem == .us ? "mi" : "km" }

    static var yAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 3)) { v in
            AxisGridLine().foregroundStyle(Color.earthTrack)
            AxisValueLabel {
                if let d = v.as(Double.self) {
                    Text("\(d.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                        .font(.wktBody(9))
                        .foregroundStyle(Color.earthMuted)
                }
            }
        }
    }

    /// "Up 12% vs last week", "Down 5% vs last month", "First activities this
    /// week" when last week had none to compare with.
    static func change(current: Double, previous: Double, period: InsightsPeriod) -> String {
        guard let change = InsightsSummary.change(current: current, previous: previous) else {
            return current > 0 ? "Nothing last \(period.noun) to compare" : "Nothing yet this \(period.noun)"
        }
        let percent = Int((abs(change) * 100).rounded())
        if percent == 0 { return "Same as last \(period.noun)" }
        return "\(change > 0 ? "Up" : "Down") \(percent)% vs last \(period.noun)"
    }

    static func versus(_ previous: Int, _ period: InsightsPeriod) -> String {
        "this time last \(period.noun) \(previous)"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
