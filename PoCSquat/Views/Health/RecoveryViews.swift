import SwiftUI
import Charts
import HealthKit

// MARK: - Recovery Metric Type

enum RecoveryMetricType: String, Identifiable {
    case sleep, readiness, calories
    var id: String { rawValue }
}

// MARK: - Recovery Card

// The first card on Health, as the Today card is on Home: last night's
// sleep, readiness and active calories, each opening its detail sheet, with
// the readiness hint and the gait status underneath.
struct RecoveryCard: View {
    private var recovery = RecoveryService.shared
    private var gait     = GaitHealthService.shared

    @State private var selectedMetric: RecoveryMetricType? = nil
    @State private var pushGaitDetail  = false

    var body: some View {
        VStack(alignment: .leading, spacing: WktSpacing.cardPadding) {
            HStack(spacing: 0) {
                metricButton(.sleep,
                    badge: WktIconBadge(symbol: .sleep, tint: .accentHealth),
                    label: "Sleep",
                    value: recovery.sleepFormatted ?? "–")
                columnDivider
                metricButton(.readiness,
                    badge: WktIconBadge(systemName: recovery.readiness.icon, tint: recovery.readiness.color),
                    label: "Readiness",
                    value: recovery.readiness.label)
                columnDivider
                metricButton(.calories,
                    badge: WktIconBadge(symbol: .calories, tint: .earthOrange),
                    label: "Active cal",
                    value: recovery.activeCal.map { "\(Int($0))" } ?? "–")
            }

            if recovery.readiness != .unknown || gaitStatus != nil {
                WktDivider()
                HStack(alignment: .center, spacing: 8) {
                    if recovery.readiness != .unknown {
                        Text(readinessLine)
                            .font(.wktLabel)
                            .foregroundColor(.earthMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if let (label, color, _) = gaitStatus {
                        WktStatusChip(text: "Gait: \(label)", dot: color) { pushGaitDetail = true }
                            .accessibilityHint("Shows walking speed")
                    }
                }
            }
        }
        .wktCard()
        .task { if recovery.activeCal == nil { await recovery.load() } }
        .sheet(item: $selectedMetric) { metric in
            RecoveryMetricDetailSheet(metric: metric)
        }
        .navigationDestination(isPresented: $pushGaitDetail) {
            if let config = GaitMetricConfig.all.first {
                GaitMetricDetailContentView(config: config, snapshots: gait.snapshots)
            }
        }
    }

    private var readinessLine: String {
        var line = recovery.readiness.hint
        if let flt = recovery.flightsClimbed, flt > 0 {
            line += " · \(flt) floor\(flt == 1 ? "" : "s")"
        }
        return line
    }

    private var gaitStatus: (label: String, color: Color, icon: String)? {
        let recent = gait.snapshots.suffix(7).compactMap { $0.speedMps }
        guard !recent.isEmpty else { return nil }
        let avg = recent.reduce(0, +) / Double(recent.count)
        guard let config = GaitMetricConfig.all.first else { return nil }
        let st = config.statusOf(avg)
        return (st.label, st.color, st.icon)
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(Color.earthTrack)
            .frame(width: 1, height: 56)
    }

    private func metricButton(_ metric: RecoveryMetricType, badge: WktIconBadge,
                              label: String, value: String) -> some View {
        Button { selectedMetric = metric } label: {
            VStack(spacing: 6) {
                badge
                Text(value)
                    .font(.wktRowTitle.monospacedDigit())
                    .foregroundColor(.earthCream)
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
                Text(label)
                    .font(.wktLabel)
                    .foregroundColor(.earthMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(BounceButtonStyle(scale: 0.95))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows details")
    }
}

// MARK: - Recovery Metric Detail Sheet

struct RecoveryMetricDetailSheet: View {
    let metric: RecoveryMetricType
    private var recovery = RecoveryService.shared
    @Environment(\.dismiss) private var dismiss

    init(metric: RecoveryMetricType) { self.metric = metric }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                        switch metric {
                        case .sleep:      sleepContent
                        case .readiness:  readinessContent
                        case .calories:   caloriesContent
                        }
                    }
                    .padding(.horizontal, WktSpacing.screen)
                    .padding(.top, 8)
                    .padding(.bottom, WktSpacing.betweenSections)
                }
            }
            .navigationTitle(metricTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.earthGreen)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var metricTitle: String {
        switch metric {
        case .sleep:     return "Sleep"
        case .readiness: return "Readiness"
        case .calories:  return "Active Calories"
        }
    }

    // MARK: ── Sleep ──────────────────────────────────────────

    private var sleepContent: some View {
        let sevenNights = recovery.sleepHistory.suffix(7).map(\.value)
        let sevenAvg    = sevenNights.isEmpty ? nil : sevenNights.reduce(0,+)/Double(sevenNights.count)
        let bestNight   = recovery.sleepHistory.map(\.value).max()
        let shortNights = recovery.sleepHistory.filter { $0.value < 7 }.count
        let sleepStatus = recovery.sleepHours.map(sleepLevel)

        return Group {
            heroHeader(
                badge: WktIconBadge(symbol: .sleep, tint: .accentHealth, size: 48),
                value: recovery.sleepFormatted ?? "–",
                subtitle: "Last night",
                statusLabel: sleepStatus?.label,
                statusColor: sleepStatus?.color
            )

            if !recovery.sleepHistory.isEmpty {
                chartSection(title: "30-night history") {
                    Chart(recovery.sleepHistory) { entry in
                        BarMark(
                            x: .value("Night", entry.date, unit: .day),
                            y: .value("Hours", entry.value)
                        )
                        .foregroundStyle(sleepLevel(entry.value).color.opacity(0.8))
                        .cornerRadius(3)
                        RuleMark(y: .value("Target", 7.0))
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                            .foregroundStyle(Color.earthGreen.opacity(0.45))
                            .annotation(position: .trailing) {
                                Text("7h").font(.wktBody(9)).foregroundColor(.earthGreen.opacity(0.7))
                            }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                .font(.wktBody(9)).foregroundStyle(Color.earthMuted)
                            AxisGridLine().foregroundStyle(Color.earthTrack)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: [0, 4, 7, 9]) { v in
                            AxisValueLabel {
                                if let d = v.as(Double.self) {
                                    Text("\(Int(d))h").font(.wktBody(9)).foregroundStyle(Color.earthMuted)
                                }
                            }
                            AxisGridLine().foregroundStyle(Color.earthTrack)
                        }
                    }
                }
            }

            statsGrid([
                ("Last night",   recovery.sleepFormatted ?? "–",                             "recorded"),
                ("7-night avg",  sevenAvg.map(RecoveryService.formatHours) ?? "–",           "last 7 nights"),
                ("Best night",   bestNight.map(RecoveryService.formatHours) ?? "–",          "last 30 nights"),
                ("Short nights", shortNights > 0 ? "\(shortNights)" : "0",                   "under 7h, last 30d")
            ])

            infoSection(title: "What this measures") {
                Text("Sleep duration is estimated from Apple Watch or iPhone motion sensors detecting when you're still. Apple Health records sleep in stages — Core (light sleep), Deep (slow-wave), and REM — as well as time in bed and any awake periods. This view shows total asleep time after merging all sources to avoid double-counting.")
                    .font(.wktBodyText).foregroundColor(.earthMuted).fixedSize(horizontal: false, vertical: true)
            }

            infoSection(title: "What affects sleep quality") {
                bulletList([
                    "Consistent bedtime — your circadian rhythm is strongest when anchored to a regular schedule",
                    "Caffeine after 2pm — caffeine has a ~6h half-life and disrupts sleep architecture",
                    "Screen light exposure in the evening suppresses melatonin production",
                    "Exercise timing — morning and afternoon exercise improves sleep; late evening can delay it",
                    "Alcohol — helps you fall asleep but significantly reduces REM and deep sleep",
                    "Room temperature — cooler rooms (65–68°F) signal your body it's time to sleep"
                ])
            }

            infoSection(title: "How to improve") {
                numberedList([
                    "Set a consistent wake-up time — even on weekends — as the foundation of sleep hygiene.",
                    "Create a 20-minute wind-down: dim lights, no screens, light reading or stretching.",
                    "Keep your bedroom for sleep and sex only — working or watching TV in bed trains your brain to stay alert there.",
                    "If you can't sleep after 20 minutes, get up and do something calm in low light until you feel sleepy.",
                    "Expose yourself to bright light within an hour of waking — this anchors your entire circadian rhythm."
                ])
            }
        }
    }

    // MARK: ── Readiness ──────────────────────────────────────

    private var readinessContent: some View {
        let hrvSeven = recovery.hrvHistory.suffix(7).map(\.value)
        let hrvAvg   = hrvSeven.isEmpty ? nil : hrvSeven.reduce(0,+)/Double(hrvSeven.count)

        let sleepScore: String = {
            guard let s = recovery.sleepHours else { return "–" }
            if s >= 7.0 { return "Good (\(RecoveryService.formatHours(s)))" }
            if s >= 6.0 { return "Fair (\(RecoveryService.formatHours(s)))" }
            return "Low (\(RecoveryService.formatHours(s)))"
        }()

        let hrvScore: String = {
            guard let h = recovery.hrv else { return "–" }
            if let b = recovery.hrvBaseline, b > 0 {
                let r = h / b
                if r >= 1.1 { return String(format: "High (%.0fms)", h) }
                if r >= 0.85 { return String(format: "Normal (%.0fms)", h) }
                return String(format: "Low (%.0fms)", h)
            }
            if h >= 50 { return String(format: "High (%.0fms)", h) }
            if h >= 20 { return String(format: "Normal (%.0fms)", h) }
            return String(format: "Low (%.0fms)", h)
        }()

        return Group {
            heroHeader(
                badge: WktIconBadge(systemName: recovery.readiness.icon, tint: recovery.readiness.color, size: 48),
                value: recovery.readiness.label,
                subtitle: recovery.readiness.hint,
                statusLabel: nil,
                statusColor: nil
            )

            if !recovery.hrvHistory.isEmpty {
                chartSection(title: "HRV, last 30 days") {
                    Chart {
                        ForEach(recovery.hrvHistory) { entry in
                            AreaMark(x: .value("Day", entry.date), y: .value("ms", entry.value))
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(LinearGradient(
                                    colors: [recovery.readiness.color.opacity(0.22), .clear],
                                    startPoint: .top, endPoint: .bottom
                                ))
                            LineMark(x: .value("Day", entry.date), y: .value("ms", entry.value))
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(recovery.readiness.color.opacity(0.9))
                                .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                        if let base = recovery.hrvBaseline {
                            RuleMark(y: .value("Baseline", base))
                                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                                .foregroundStyle(Color.earthMuted.opacity(0.5))
                                .annotation(position: .trailing) {
                                    Text("Avg").font(.wktBody(9)).foregroundColor(.earthMuted.opacity(0.7))
                                }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                .font(.wktBody(9)).foregroundStyle(Color.earthMuted)
                            AxisGridLine().foregroundStyle(Color.earthTrack)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { v in
                            AxisValueLabel {
                                if let d = v.as(Double.self) {
                                    Text("\(Int(d))ms").font(.wktBody(9)).foregroundStyle(Color.earthMuted)
                                }
                            }
                            AxisGridLine().foregroundStyle(Color.earthTrack)
                        }
                    }
                }
            }

            scoreBreakdown(sleepScore: sleepScore, hrvScore: hrvScore)

            statsGrid([
                ("HRV now",       recovery.hrv.map       { String(format: "%.0fms", $0) } ?? "–", "heart rate variability"),
                ("HRV baseline",  recovery.hrvBaseline.map { String(format: "%.0fms", $0) } ?? "–", "30-day personal avg"),
                ("7-day HRV avg", hrvAvg.map              { String(format: "%.0fms", $0) } ?? "–", "this week"),
                ("Sleep input",   recovery.sleepFormatted ?? "–",                                   "last night")
            ])

            infoSection(title: "How readiness is calculated") {
                Text("Readiness combines two signals: your Heart Rate Variability (HRV) compared to your personal 30-day baseline, and last night's sleep duration. Both signals are scored 0–2 and averaged. A combined score above 1.7 is Push, above 0.8 is Active, and below that is Recover. If only one signal is available, it's used alone.")
                    .font(.wktBodyText).foregroundColor(.earthMuted).fixedSize(horizontal: false, vertical: true)
            }

            infoSection(title: "What is HRV?") {
                Text("Heart Rate Variability is the variation in time between consecutive heartbeats. Counterintuitively, more variation is better — it means your autonomic nervous system is adaptable. A high HRV relative to your baseline indicates your body recovered well. HRV is recorded by Apple Watch during sleep or during Breathe sessions.")
                    .font(.wktBodyText).foregroundColor(.earthMuted).fixedSize(horizontal: false, vertical: true)
            }

            infoSection(title: "What affects readiness") {
                bulletList([
                    "Sleep quality and duration — the single largest driver of readiness",
                    "Overtraining or high training load from previous days",
                    "Illness or immune activation significantly drops HRV",
                    "Alcohol — even moderate amounts suppress HRV for 24–48h",
                    "Mental or emotional stress activates the sympathetic nervous system",
                    "Hydration and nutrition — electrolyte balance affects heart rhythm"
                ])
            }

            infoSection(title: "How to improve") {
                numberedList([
                    "Prioritise sleep — it's the most powerful single intervention for HRV.",
                    "Build a balanced training load: alternate high-effort days with easy recovery days.",
                    "Manage stress through breathwork, meditation, or time in nature — all measurably increase HRV.",
                    "Avoid alcohol within 3 hours of bedtime; even small amounts reduce HRV.",
                    "Cold exposure (cold showers, cold water swimming) has shown consistent HRV benefits in research."
                ])
            }
        }
    }

    // MARK: ── Calories ──────────────────────────────────────

    private var caloriesContent: some View {
        let calValues  = recovery.calHistory.map(\.value)
        let sevenAvg   = calValues.suffix(7).isEmpty ? nil
                            : calValues.suffix(7).reduce(0,+) / Double(calValues.suffix(7).count)
        let thirtyAvg  = calValues.isEmpty ? nil : calValues.reduce(0,+) / Double(calValues.count)
        let best       = calValues.max()
        let monthTotal = calValues.reduce(0, +)

        return Group {
            heroHeader(
                badge: WktIconBadge(symbol: .calories, tint: .earthOrange, size: 48),
                value: recovery.activeCal.map { "\(Int($0)) cal" } ?? "–",
                subtitle: "Active calories today",
                statusLabel: nil,
                statusColor: nil
            )

            if !recovery.calHistory.isEmpty {
                chartSection(title: "Active calories, last 30 days") {
                    Chart {
                        ForEach(recovery.calHistory) { entry in
                            BarMark(
                                x: .value("Day", entry.date, unit: .day),
                                y: .value("kcal", entry.value)
                            )
                            .foregroundStyle(Color.earthOrange.opacity(0.75))
                            .cornerRadius(3)
                        }
                        if let avg = thirtyAvg {
                            RuleMark(y: .value("Avg", avg))
                                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                                .foregroundStyle(Color.earthMuted.opacity(0.55))
                                .annotation(position: .trailing) {
                                    Text("Avg").font(.wktBody(9)).foregroundColor(.earthMuted.opacity(0.7))
                                }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                .font(.wktBody(9)).foregroundStyle(Color.earthMuted)
                            AxisGridLine().foregroundStyle(Color.earthTrack)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { v in
                            AxisValueLabel {
                                if let d = v.as(Double.self) {
                                    Text("\(Int(d))").font(.wktBody(9)).foregroundStyle(Color.earthMuted)
                                }
                            }
                            AxisGridLine().foregroundStyle(Color.earthTrack)
                        }
                    }
                }
            }

            statsGrid([
                ("Today",        recovery.activeCal.map { "\(Int($0)) cal" } ?? "–", "so far"),
                ("7-day avg",    sevenAvg.map  { "\(Int($0)) cal" } ?? "–",          "this week"),
                ("Best day",     best.map      { "\(Int($0)) cal" } ?? "–",          "last 30 days"),
                ("30-day total", monthTotal > 0 ? "\(Int(monthTotal)) cal" : "–",    "last 30 days")
            ])

            infoSection(title: "What this measures") {
                Text("Active calories (also called Exercise Calories) are the calories your body burns above its resting baseline due to movement. This is distinct from Total Calories, which includes your resting metabolic rate. Active calories are tracked using iPhone and Apple Watch motion, heart rate, and personal health data to estimate energy expenditure during movement.")
                    .font(.wktBodyText).foregroundColor(.earthMuted).fixedSize(horizontal: false, vertical: true)
            }

            infoSection(title: "NEAT, the hidden calorie burn") {
                Text("Non-Exercise Activity Thermogenesis (NEAT) is movement that isn't formal exercise — fidgeting, walking to meetings, taking stairs, standing vs sitting. Research shows NEAT can account for up to 2,000 extra calories per day in highly active people. Most wearable calorie estimates include NEAT, making it a key lever for total daily energy.")
                    .font(.wktBodyText).foregroundColor(.earthMuted).fixedSize(horizontal: false, vertical: true)
            }

            infoSection(title: "What affects daily calories") {
                bulletList([
                    "Physical activity type and intensity — cardio burns more acutely, strength more over 24h",
                    "Non-exercise movement (NEAT) — standing, walking, and fidgeting add up significantly",
                    "Body mass — larger bodies burn more calories at the same effort",
                    "Temperature — cold environments increase calorie burn to maintain core temperature",
                    "Fitness level — highly fit individuals are more efficient and burn slightly fewer calories"
                ])
            }

            infoSection(title: "How to burn more") {
                numberedList([
                    "Increase NEAT first — stand instead of sit, walk during calls, take stairs. Small choices add hundreds of calories.",
                    "Add one brisk 20-minute walk to your day — it's the most sustainable calorie-burning activity for most people.",
                    "Resistance training builds muscle, which raises your resting metabolic rate permanently.",
                    "Pace or move while on the phone — most people make 20–40 minutes of calls per day.",
                    "Park further away, get off transit one stop early — these habits become automatic very quickly."
                ])
            }
        }
    }

    // MARK: - Shared layout helpers

    // Thin adapters onto the shared metric-screen pieces (WktDetailPieces.swift),
    // so the three metrics above read as plain data.

    @ViewBuilder
    private func heroHeader(
        badge: WktIconBadge,
        value: String, subtitle: String,
        statusLabel: String?, statusColor: Color?
    ) -> some View {
        if let label = statusLabel, let color = statusColor {
            WktMetricHero(badge: badge, value: value, subtitle: subtitle) {
                WktStatusChip(text: label, dot: color)
            }
        } else {
            WktMetricHero(badge: badge, value: value, subtitle: subtitle)
        }
    }

    private func chartSection<C: View>(title: String, @ViewBuilder content: @escaping () -> C) -> some View {
        WktSection(title: title) {
            content()
                .frame(height: 160)
                .wktCard()
        }
    }

    private func statsGrid(_ items: [(String, String, String)]) -> some View {
        WktStatGrid(items: items.map { WktStatGrid.Item(label: $0.0, value: $0.1, note: $0.2) })
    }

    private func infoSection<Content: View>(
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        WktInfoSection(title: title, content: content)
    }

    private func bulletList(_ items: [String]) -> some View { WktBulletList(items: items) }

    private func numberedList(_ items: [String]) -> some View { WktNumberedList(items: items) }

    private func scoreBreakdown(sleepScore: String, hrvScore: String) -> some View {
        WktSection(title: "Score breakdown") {
            HStack(spacing: WktSpacing.betweenCards) {
                scoreComponent(badge: WktIconBadge(symbol: .sleep, tint: .accentHealth),
                               label: "Sleep", value: sleepScore)
                scoreComponent(badge: WktIconBadge(symbol: .readiness, tint: recovery.readiness.color),
                               label: "HRV", value: hrvScore)
            }
        }
    }

    private func scoreComponent(badge: WktIconBadge, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                badge
                Text(label)
                    .font(.wktLabel)
                    .foregroundColor(.earthMuted)
            }
            Text(value)
                .font(.wktRowTitle)
                .foregroundColor(.earthCream)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .wktCard()
        .accessibilityElement(children: .combine)
    }

    private func sleepLevel(_ hours: Double) -> (label: String, color: Color) {
        if hours >= 7.5 { return ("Excellent", .earthGreen) }
        if hours >= 7.0 { return ("Good",      .earthGreen) }
        if hours >= 6.0 { return ("Fair",       Color.accentNotice) }
        return ("Short", .earthOrange)
    }
}
