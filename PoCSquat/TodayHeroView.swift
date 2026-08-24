import SwiftUI
import Charts
import HealthKit

// MARK: - Intraday Step Service

@Observable
final class IntradayStepService {
    static let shared = IntradayStepService()
    private init() {}

    var hourlySteps: [Int] = Array(repeating: 0, count: 24)
    private(set) var isLoading = false

    private let store = HKHealthStore()

    var peakHour: Int? {
        guard let max = hourlySteps.max(), max > 0,
              let idx = hourlySteps.firstIndex(of: max) else { return nil }
        return idx
    }

    var totalSoFar: Int { hourlySteps.reduce(0, +) }

    func load() async {
        guard !isLoading, HKHealthStore.isHealthDataAvailable() else { return }
        isLoading = true
        defer { isLoading = false }

        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        let now   = Date()
        let pred  = HKQuery.predicateForSamples(withStart: today, end: now)

        let counts: [Int] = await withCheckedContinuation { cont in
            let q = HKStatisticsCollectionQuery(
                quantityType: HKQuantityType(.stepCount),
                quantitySamplePredicate: pred,
                options: .cumulativeSum,
                anchorDate: today,
                intervalComponents: DateComponents(hour: 1)
            )
            q.initialResultsHandler = { _, results, _ in
                var hourly = [Int](repeating: 0, count: 24)
                results?.enumerateStatistics(from: today, to: now) { stat, _ in
                    let hour  = cal.component(.hour, from: stat.startDate)
                    let steps = stat.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    if hour >= 0 && hour < 24 { hourly[hour] = Int(steps) }
                }
                cont.resume(returning: hourly)
            }
            self.store.execute(q)
        }
        hourlySteps = counts
    }
}

// MARK: - Journey Track

struct JourneyTrackView: View {
    let progress: Double
    let avatarEmoji: String

    private var intraday = IntradayStepService.shared

    init(progress: Double, avatarEmoji: String) {
        self.progress    = progress
        self.avatarEmoji = avatarEmoji
    }

    private let checkpoints: [Double] = [0.25, 0.5, 0.75, 1.0]
    @State private var reachedSet: Set<Int> = []
    @State private var pulsing:    Set<Int> = []

    var body: some View {
        VStack(spacing: 4) {
            // Progress track
            GeometryReader { geo in
                let W     = geo.size.width
                let P     = min(max(progress, 0), 1.0)
                let fillW = max(8.0, W * P)

                ZStack {
                    // Background track
                    Capsule()
                        .fill(Color.earthMuted.opacity(0.12))
                        .frame(width: W, height: 8)
                        .position(x: W / 2, y: 44)

                    // Filled track with progress-aware gradient
                    Capsule()
                        .fill(progressGradient(P))
                        .frame(width: fillW, height: 8)
                        .position(x: fillW / 2, y: 44)
                        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: P)

                    // Checkpoint dots
                    ForEach(checkpoints.indices, id: \.self) { i in
                        let cx      = W * checkpoints[i]
                        let reached = progress >= checkpoints[i]
                        ZStack {
                            if pulsing.contains(i) {
                                Circle()
                                    .fill(Color.earthGreen.opacity(0.25))
                                    .frame(width: 24, height: 24)
                                    .scaleEffect(pulsing.contains(i) ? 1.5 : 0.5)
                                    .opacity(pulsing.contains(i) ? 0.0 : 0.5)
                                    .animation(.easeOut(duration: 0.6), value: pulsing.contains(i))
                            }
                            Circle()
                                .fill(reached ? Color.earthGreen : Color.earthMuted.opacity(0.22))
                                .frame(width: 11, height: 11)
                                .overlay(Circle().stroke(Color.earthBg, lineWidth: 2))
                                .scaleEffect(pulsing.contains(i) ? 1.45 : 1.0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: pulsing.contains(i))
                        }
                        .position(x: cx, y: 44)
                    }

                    // Finish flag
                    Text("🏁").font(.system(size: 15)).position(x: W, y: 28)

                    // Avatar: glow ring + emoji flipped to face direction of travel
                    let avatarX = max(13, min(W - 8, W * P))
                    ZStack {
                        // Glow intensifies as goal approaches
                        Circle()
                            .fill(glowColor(P).opacity(avatarGlowOpacity(P)))
                            .frame(width: 40, height: 40)
                            .blur(radius: 5)
                        Text(avatarEmoji)
                            .font(.system(size: 26))
                            .scaleEffect(x: -1, y: 1)  // flip to face direction of travel
                    }
                    .position(x: avatarX, y: 18)
                    .animation(.spring(response: 0.55, dampingFraction: 0.78), value: P)
                }
                .frame(width: W, height: 56)
                .onChange(of: progress) { _, newVal in
                    for (i, cp) in checkpoints.enumerated() {
                        guard newVal >= cp, !reachedSet.contains(i) else { continue }
                        reachedSet.insert(i)
                        withAnimation { _ = pulsing.insert(i) }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 650_000_000)
                            withAnimation { _ = pulsing.remove(i) }
                        }
                    }
                }
                .onAppear {
                    for (i, cp) in checkpoints.enumerated() {
                        if progress >= cp { reachedSet.insert(i) }
                    }
                }
            }
            .frame(height: 56)

            // Hourly activity bars
            HourlyStepBars(hourlySteps: intraday.hourlySteps, peakHour: intraday.peakHour)
        }
        .padding(.horizontal, 20)
        .task { await intraday.load() }
        .task(id: Int(progress * 20)) {
            // Reload at most once per 5% progress change
            await intraday.load()
        }
    }

    // Gradient shifts: muted → bright green → gold at goal
    private func progressGradient(_ p: Double) -> LinearGradient {
        let colors: [Color]
        if p >= 1.0 {
            colors = [Color(red: 0.78, green: 0.62, blue: 0.08), Color(red: 0.52, green: 0.88, blue: 0.40)]
        } else if p >= 0.75 {
            colors = [Color.earthGreen, Color(red: 0.52, green: 0.76, blue: 0.38)]
        } else if p >= 0.4 {
            colors = [Color.earthGreen.opacity(0.8), Color.earthGreen]
        } else {
            colors = [Color.earthGreen.opacity(0.6), Color.earthGreen.opacity(0.85)]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    private func glowColor(_ p: Double) -> Color {
        p >= 1.0 ? Color(red: 0.95, green: 0.80, blue: 0.15) : Color.earthGreen
    }

    // Glow fades in from 40% progress, maxes out at 100%
    private func avatarGlowOpacity(_ p: Double) -> Double {
        guard p > 0.4 else { return 0 }
        return min((p - 0.4) / 0.6 * 0.55, 0.55)
    }
}

// MARK: - Hourly Step Bars

private struct HourlyStepBars: View {
    let hourlySteps: [Int]
    let peakHour:    Int?

    private var currentHour: Int { Calendar.current.component(.hour, from: Date()) }
    private var maxSteps:    Int { max(1, hourlySteps.max() ?? 1) }

    // Label positions: midnight, 6am, noon, 6pm, now
    private let labelHours: [Int] = [0, 6, 12, 18]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Bar chart
            GeometryReader { geo in
                let spacing: CGFloat = 1
                let barW = (geo.size.width - spacing * 23) / 24

                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(0..<24, id: \.self) { hour in
                        let steps    = hour < hourlySteps.count ? hourlySteps[hour] : 0
                        let isFuture = hour > currentHour
                        let isNow    = hour == currentHour
                        let isPeak   = hour == peakHour
                        let rawH     = CGFloat(steps) / CGFloat(maxSteps) * geo.size.height
                        let barH     = isFuture ? 2 : max(2, rawH)

                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(barFill(hour: hour, isFuture: isFuture, isNow: isNow, isPeak: isPeak, steps: steps))
                            .frame(width: barW, height: barH)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 22)

            // Time axis labels
            HStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    if labelHours.contains(hour) {
                        Text(hourLabel(hour))
                            .font(.system(size: 8))
                            .foregroundColor(.earthMuted.opacity(0.45))
                    } else if hour == currentHour {
                        Text("Now")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.earthGreen.opacity(0.7))
                    } else {
                        Color.clear
                    }
                    if hour < 23 { Spacer(minLength: 0) }
                }
            }
        }
    }

    private func barFill(hour: Int, isFuture: Bool, isNow: Bool, isPeak: Bool, steps: Int) -> Color {
        if isFuture         { return Color.earthMuted.opacity(0.07) }
        if steps == 0       { return Color.earthMuted.opacity(0.10) }
        if isNow            { return Color.earthGreen }
        if isPeak           { return Color(red: 0.52, green: 0.80, blue: 0.40) }
        return Color.earthGreen.opacity(0.48)
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0:  return "12a"
        case 6:  return "6a"
        case 12: return "12p"
        case 18: return "6p"
        default: return ""
        }
    }
}

// MARK: - Recovery Metric Type

enum RecoveryMetricType: String, Identifiable {
    case sleep, readiness, calories
    var id: String { rawValue }
}

// MARK: - Recovery Card

struct RecoveryCard: View {
    private var recovery = RecoveryService.shared
    private var gait     = GaitHealthService.shared

    @State private var selectedMetric: RecoveryMetricType? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                pillButton(metric: .sleep,
                    icon:  "bed.double.fill",
                    label: "Sleep",
                    value: recovery.sleepFormatted ?? "–",
                    color: Color(red: 0.42, green: 0.52, blue: 0.88)
                )
                pillDivider
                pillButton(metric: .readiness,
                    icon:  recovery.readiness.icon,
                    label: "Readiness",
                    value: recovery.readiness.label,
                    color: recovery.readiness.color
                )
                pillDivider
                pillButton(metric: .calories,
                    icon:  "flame.fill",
                    label: "Active Cal",
                    value: recovery.activeCal.map { "\(Int($0))" } ?? "–",
                    color: .earthOrange
                )
            }
            .padding(.vertical, 13)

            if recovery.readiness != .unknown || gaitStatus != nil {
                Divider().background(Color.earthMuted.opacity(0.13))

                HStack(spacing: 6) {
                    if recovery.readiness != .unknown {
                        Image(systemName: recovery.readiness.icon)
                            .font(.caption2)
                            .foregroundColor(recovery.readiness.color)
                        Text(recovery.readiness.hint)
                            .font(.caption2)
                            .foregroundColor(.earthMuted)
                        if let flt = recovery.flightsClimbed, flt > 0 {
                            Text("· \(flt) floor\(flt == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundColor(.earthMuted.opacity(0.55))
                        }
                    }
                    Spacer()
                    if let (label, color, icon) = gaitStatus {
                        Label("Gait: \(label)", systemImage: icon)
                            .font(.caption2.bold())
                            .foregroundColor(color)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .background(Color.earthCard)
        .cornerRadius(16)
        .padding(.horizontal, 20)
        .task { if recovery.activeCal == nil { await recovery.load() } }
        .sheet(item: $selectedMetric) { metric in
            RecoveryMetricDetailSheet(metric: metric)
        }
    }

    private var gaitStatus: (label: String, color: Color, icon: String)? {
        let recent = gait.snapshots.suffix(7).compactMap { $0.speedMps }
        guard !recent.isEmpty else { return nil }
        let avg = recent.reduce(0, +) / Double(recent.count)
        guard let config = GaitMetricConfig.all.first else { return nil }
        let st = config.statusOf(avg)
        return (st.label, st.color, st.icon)
    }

    private var pillDivider: some View {
        Rectangle()
            .fill(Color.earthMuted.opacity(0.13))
            .frame(width: 1, height: 34)
    }

    private func pillButton(
        metric: RecoveryMetricType,
        icon: String, label: String, value: String, color: Color
    ) -> some View {
        Button { selectedMetric = metric } label: {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(color)
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(.earthCream)
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
                HStack(spacing: 2) {
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundColor(.earthMuted)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(.earthMuted.opacity(0.45))
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    VStack(alignment: .leading, spacing: 24) {
                        switch metric {
                        case .sleep:      sleepContent
                        case .readiness:  readinessContent
                        case .calories:   caloriesContent
                        }
                    }
                    .padding(.bottom, 40)
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
                icon: "bed.double.fill",
                color: Color(red: 0.42, green: 0.52, blue: 0.88),
                value: recovery.sleepFormatted ?? "–",
                subtitle: "Last night",
                statusLabel: sleepStatus?.label,
                statusColor: sleepStatus?.color
            )

            if !recovery.sleepHistory.isEmpty {
                chartSection(title: "30-Night History") {
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
                                Text("7h").font(.system(size: 9)).foregroundColor(.earthGreen.opacity(0.7))
                            }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                .font(.system(size: 9)).foregroundStyle(Color.earthMuted)
                            AxisGridLine().foregroundStyle(Color.earthMuted.opacity(0.1))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: [0, 4, 7, 9]) { v in
                            AxisValueLabel {
                                if let d = v.as(Double.self) {
                                    Text("\(Int(d))h").font(.system(size: 9)).foregroundStyle(Color.earthMuted)
                                }
                            }
                            AxisGridLine().foregroundStyle(Color.earthMuted.opacity(0.1))
                        }
                    }
                }
            }

            statsGrid([
                ("Last Night",   recovery.sleepFormatted ?? "–",                             "recorded"),
                ("7-Night Avg",  sevenAvg.map(RecoveryService.formatHours) ?? "–",           "last 7 nights"),
                ("Best Night",   bestNight.map(RecoveryService.formatHours) ?? "–",          "last 30 nights"),
                ("Short Nights", shortNights > 0 ? "\(shortNights)" : "0",                   "under 7h, last 30d")
            ])

            infoSection(title: "What This Measures", icon: "info.circle.fill",
                        color: Color(red: 0.42, green: 0.52, blue: 0.88)) {
                Text("Sleep duration is estimated from Apple Watch or iPhone motion sensors detecting when you're still. Apple Health records sleep in stages — Core (light sleep), Deep (slow-wave), and REM — as well as time in bed and any awake periods. This view shows total asleep time after merging all sources to avoid double-counting.")
                    .font(.subheadline).foregroundColor(.earthMuted).fixedSize(horizontal: false, vertical: true)
            }

            infoSection(title: "What Affects Sleep Quality", icon: "moon.fill", color: .earthOrange) {
                bulletList([
                    "Consistent bedtime — your circadian rhythm is strongest when anchored to a regular schedule",
                    "Caffeine after 2pm — caffeine has a ~6h half-life and disrupts sleep architecture",
                    "Screen light exposure in the evening suppresses melatonin production",
                    "Exercise timing — morning and afternoon exercise improves sleep; late evening can delay it",
                    "Alcohol — helps you fall asleep but significantly reduces REM and deep sleep",
                    "Room temperature — cooler rooms (65–68°F) signal your body it's time to sleep"
                ])
            }

            infoSection(title: "How to Improve", icon: "lightbulb.fill", color: .earthGreen) {
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
                icon: recovery.readiness.icon,
                color: recovery.readiness.color,
                value: recovery.readiness.label,
                subtitle: recovery.readiness.hint,
                statusLabel: nil,
                statusColor: nil
            )

            if !recovery.hrvHistory.isEmpty {
                chartSection(title: "HRV — 30-Day Trend") {
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
                                    Text("Avg").font(.system(size: 9)).foregroundColor(.earthMuted.opacity(0.7))
                                }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                .font(.system(size: 9)).foregroundStyle(Color.earthMuted)
                            AxisGridLine().foregroundStyle(Color.earthMuted.opacity(0.1))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { v in
                            AxisValueLabel {
                                if let d = v.as(Double.self) {
                                    Text("\(Int(d))ms").font(.system(size: 9)).foregroundStyle(Color.earthMuted)
                                }
                            }
                            AxisGridLine().foregroundStyle(Color.earthMuted.opacity(0.1))
                        }
                    }
                }
            }

            scoreBreakdown(sleepScore: sleepScore, hrvScore: hrvScore)

            statsGrid([
                ("HRV Now",       recovery.hrv.map       { String(format: "%.0fms", $0) } ?? "–", "heart rate variability"),
                ("HRV Baseline",  recovery.hrvBaseline.map { String(format: "%.0fms", $0) } ?? "–", "30-day personal avg"),
                ("7-Day HRV Avg", hrvAvg.map              { String(format: "%.0fms", $0) } ?? "–", "this week"),
                ("Sleep Input",   recovery.sleepFormatted ?? "–",                                   "last night")
            ])

            infoSection(title: "How Readiness Is Calculated", icon: "info.circle.fill",
                        color: recovery.readiness.color) {
                Text("Readiness combines two signals: your Heart Rate Variability (HRV) compared to your personal 30-day baseline, and last night's sleep duration. Both signals are scored 0–2 and averaged. A combined score above 1.7 is Push, above 0.8 is Active, and below that is Recover. If only one signal is available, it's used alone.")
                    .font(.subheadline).foregroundColor(.earthMuted).fixedSize(horizontal: false, vertical: true)
            }

            infoSection(title: "What Is HRV?", icon: "waveform.path.ecg", color: Color(red: 0.42, green: 0.52, blue: 0.88)) {
                Text("Heart Rate Variability is the variation in time between consecutive heartbeats. Counterintuitively, more variation is better — it means your autonomic nervous system is adaptable. A high HRV relative to your baseline indicates your body recovered well. HRV is recorded by Apple Watch during sleep or during Breathe sessions.")
                    .font(.subheadline).foregroundColor(.earthMuted).fixedSize(horizontal: false, vertical: true)
            }

            infoSection(title: "What Affects Readiness", icon: "chart.bar.fill", color: .earthOrange) {
                bulletList([
                    "Sleep quality and duration — the single largest driver of readiness",
                    "Overtraining or high training load from previous days",
                    "Illness or immune activation significantly drops HRV",
                    "Alcohol — even moderate amounts suppress HRV for 24–48h",
                    "Mental or emotional stress activates the sympathetic nervous system",
                    "Hydration and nutrition — electrolyte balance affects heart rhythm"
                ])
            }

            infoSection(title: "How to Improve", icon: "lightbulb.fill", color: .earthGreen) {
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
                icon: "flame.fill",
                color: .earthOrange,
                value: recovery.activeCal.map { "\(Int($0)) cal" } ?? "–",
                subtitle: "Active calories today",
                statusLabel: nil,
                statusColor: nil
            )

            if !recovery.calHistory.isEmpty {
                chartSection(title: "30-Day Active Calories") {
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
                                    Text("Avg").font(.system(size: 9)).foregroundColor(.earthMuted.opacity(0.7))
                                }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                .font(.system(size: 9)).foregroundStyle(Color.earthMuted)
                            AxisGridLine().foregroundStyle(Color.earthMuted.opacity(0.1))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { v in
                            AxisValueLabel {
                                if let d = v.as(Double.self) {
                                    Text("\(Int(d))").font(.system(size: 9)).foregroundStyle(Color.earthMuted)
                                }
                            }
                            AxisGridLine().foregroundStyle(Color.earthMuted.opacity(0.1))
                        }
                    }
                }
            }

            statsGrid([
                ("Today",        recovery.activeCal.map { "\(Int($0)) cal" } ?? "–", "so far"),
                ("7-Day Avg",    sevenAvg.map  { "\(Int($0)) cal" } ?? "–",          "this week"),
                ("Best Day",     best.map      { "\(Int($0)) cal" } ?? "–",          "last 30 days"),
                ("30-Day Total", monthTotal > 0 ? "\(Int(monthTotal)) cal" : "–",    "last 30 days")
            ])

            infoSection(title: "What This Measures", icon: "info.circle.fill", color: .earthOrange) {
                Text("Active calories (also called Exercise Calories) are the calories your body burns above its resting baseline due to movement. This is distinct from Total Calories, which includes your resting metabolic rate. Active calories are tracked using iPhone and Apple Watch motion, heart rate, and personal health data to estimate energy expenditure during movement.")
                    .font(.subheadline).foregroundColor(.earthMuted).fixedSize(horizontal: false, vertical: true)
            }

            infoSection(title: "NEAT — The Hidden Calorie Burn", icon: "figure.walk", color: Color(red: 0.42, green: 0.52, blue: 0.88)) {
                Text("Non-Exercise Activity Thermogenesis (NEAT) is movement that isn't formal exercise — fidgeting, walking to meetings, taking stairs, standing vs sitting. Research shows NEAT can account for up to 2,000 extra calories per day in highly active people. Most wearable calorie estimates include NEAT, making it a key lever for total daily energy.")
                    .font(.subheadline).foregroundColor(.earthMuted).fixedSize(horizontal: false, vertical: true)
            }

            infoSection(title: "What Affects Daily Calories", icon: "chart.bar.fill", color: .earthOrange) {
                bulletList([
                    "Physical activity type and intensity — cardio burns more acutely, strength more over 24h",
                    "Non-exercise movement (NEAT) — standing, walking, and fidgeting add up significantly",
                    "Body mass — larger bodies burn more calories at the same effort",
                    "Temperature — cold environments increase calorie burn to maintain core temperature",
                    "Fitness level — highly fit individuals are more efficient and burn slightly fewer calories"
                ])
            }

            infoSection(title: "How to Burn More", icon: "lightbulb.fill", color: .earthGreen) {
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

    private func heroHeader(
        icon: String, color: Color,
        value: String, subtitle: String,
        statusLabel: String?, statusColor: Color?
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(color.opacity(0.12))
                    .frame(width: 56, height: 56)
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(.earthCream)
                if let label = statusLabel, let scolor = statusColor {
                    Text(label)
                        .font(.caption.bold())
                        .foregroundColor(scolor)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(scolor.opacity(0.12))
                        .cornerRadius(8)
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.earthMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func chartSection<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundColor(.earthCream)
                .padding(.horizontal, 20)
            content()
                .frame(height: 160)
                .padding(.horizontal, 20)
        }
    }

    private func statsGrid(_ items: [(String, String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(items.indices, id: \.self) { i in
                let (label, value, note) = items[i]
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(.caption2.bold())
                        .foregroundColor(.earthMuted)
                    Text(value)
                        .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundColor(.earthCream)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundColor(.earthMuted.opacity(0.6))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.earthCard)
                .cornerRadius(14)
            }
        }
        .padding(.horizontal, 20)
    }

    private func infoSection<Content: View>(
        title: String, icon: String, color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.subheadline.bold())
                .foregroundColor(color)
            content()
        }
        .padding(16)
        .background(Color.earthCard)
        .cornerRadius(16)
        .padding(.horizontal, 20)
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color.earthOrange.opacity(0.7))
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    Text(item)
                        .font(.subheadline)
                        .foregroundColor(.earthMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func numberedList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(items.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.earthGreen.opacity(0.15))
                            .frame(width: 24, height: 24)
                        Text("\(i + 1)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.earthGreen)
                    }
                    Text(items[i])
                        .font(.subheadline)
                        .foregroundColor(.earthMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func scoreBreakdown(sleepScore: String, hrvScore: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Score Breakdown")
                .font(.subheadline.bold())
                .foregroundColor(.earthCream)
            HStack(spacing: 12) {
                scoreComponent(icon: "bed.double.fill",
                               color: Color(red: 0.42, green: 0.52, blue: 0.88),
                               label: "Sleep", value: sleepScore)
                scoreComponent(icon: "waveform.path.ecg",
                               color: recovery.readiness.color,
                               label: "HRV", value: hrvScore)
            }
        }
        .padding(16)
        .background(Color.earthCard)
        .cornerRadius(16)
        .padding(.horizontal, 20)
    }

    private func scoreComponent(icon: String, color: Color, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: icon)
                .font(.caption.bold())
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.earthCream)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .cornerRadius(10)
    }

    private func sleepLevel(_ hours: Double) -> (label: String, color: Color) {
        if hours >= 7.5 { return ("Excellent", .earthGreen) }
        if hours >= 7.0 { return ("Good",      .earthGreen) }
        if hours >= 6.0 { return ("Fair",       Color(red: 0.82, green: 0.70, blue: 0.05)) }
        return ("Short", .earthOrange)
    }
}
