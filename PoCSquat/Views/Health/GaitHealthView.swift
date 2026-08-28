import SwiftUI
import HealthKit
import Charts

// MARK: - Data Model

struct GaitDaySnapshot: Identifiable {
    let id: Date
    let date: Date
    var speedMps: Double?          // m/s — higher is better
    var stepLengthCm: Double?      // cm  — higher is better
    var doubleSupportPct: Double?  // %   — lower is better
    var asymmetryPct: Double?      // %   — lower is better
}

// MARK: - Service

@Observable
final class GaitHealthService {
    static let shared = GaitHealthService()

    var snapshots: [GaitDaySnapshot] = []
    var isLoading = false

    var hasAnyData: Bool {
        snapshots.contains { $0.speedMps != nil }
    }

    static var readTypes: Set<HKQuantityType> {
        [
            HKQuantityType(.walkingSpeed),
            HKQuantityType(.walkingStepLength),
            HKQuantityType(.walkingDoubleSupportPercentage),
            HKQuantityType(.walkingAsymmetryPercentage)
        ]
    }

    private let store = HKHealthStore()

    func load() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        isLoading = true
        defer { isLoading = false }

        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -29, to: today)!
        let end   = Date()

        async let s = dailyAverages(.walkingSpeed,                   unit: HKUnit.meter().unitDivided(by: .second()), from: start, to: end)
        async let l = dailyAverages(.walkingStepLength,              unit: .meter(),   from: start, to: end)
        async let d = dailyAverages(.walkingDoubleSupportPercentage, unit: .percent(), from: start, to: end)
        async let a = dailyAverages(.walkingAsymmetryPercentage,     unit: .percent(), from: start, to: end)

        let (speeds, lengths, dblSupport, asymm) = await (s, l, d, a)

        snapshots = (0..<30).compactMap { i in
            guard let date = cal.date(byAdding: .day, value: i, to: start) else { return nil }
            let day = cal.startOfDay(for: date)
            return GaitDaySnapshot(
                id:               day,
                date:             day,
                speedMps:         speeds[day],
                stepLengthCm:     lengths[day].map { $0 * 100 },
                doubleSupportPct: dblSupport[day].map { $0 * 100 },
                asymmetryPct:     asymm[day].map { $0 * 100 }
            )
        }
    }

    private func dailyAverages(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async -> [Date: Double] {
        let type      = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let cal       = Calendar.current
        return await withCheckedContinuation { cont in
            let q = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage,
                anchorDate: start,
                intervalComponents: DateComponents(day: 1)
            )
            q.initialResultsHandler = { _, results, _ in
                var out: [Date: Double] = [:]
                results?.enumerateStatistics(from: start, to: end) { stat, _ in
                    guard let v = stat.averageQuantity()?.doubleValue(for: unit) else { return }
                    out[cal.startOfDay(for: stat.startDate)] = v
                }
                cont.resume(returning: out)
            }
            self.store.execute(q)
        }
    }
}

// MARK: - Status

enum GaitStatus {
    case good, notice, attention

    var label: String {
        switch self {
        case .good:      return "On track"
        case .notice:    return "Watch"
        case .attention: return "Check in"
        }
    }

    var color: Color {
        switch self {
        case .good:      return .earthGreen
        case .notice:    return Color(red: 0.82, green: 0.70, blue: 0.05)
        case .attention: return .earthOrange
        }
    }

    var icon: String {
        switch self {
        case .good:      return "checkmark.circle.fill"
        case .notice:    return "circle.dotted"
        case .attention: return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Metric Config

struct GaitMetricConfig: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let unit: String
    let higherIsBetter: Bool
    let format: (Double) -> String
    let values: (GaitDaySnapshot) -> Double?
    let statusOf: (Double) -> GaitStatus
    let goodThresholdRaw: Double    // in same units as values() output, for chart reference line
    let normalRange: String
    let explanation: String
    let whatAffects: [String]
    let tips: [String]

    static let all: [GaitMetricConfig] = [
        GaitMetricConfig(
            id: "speed",
            title: "Walking Speed",
            systemImage: "figure.walk.motion",
            unit: "km/h",
            higherIsBetter: true,
            format: { String(format: "%.1f km/h", $0 * 3.6) },
            values: { $0.speedMps },
            statusOf: {
                let kmh = $0 * 3.6
                if kmh >= 4.0 { return .good }
                if kmh >= 3.2 { return .notice }
                return .attention
            },
            goodThresholdRaw: 4.0 / 3.6,   // 4.0 km/h in m/s
            normalRange: "3.5 – 5.5 km/h",
            explanation: "Your average walking pace across all detected walking bouts. iPhone uses motion sensors to detect natural walking and records the speed throughout the day — not just during tracked workouts.",
            whatAffects: [
                "Cardiovascular fitness and aerobic capacity",
                "Leg muscle strength and power",
                "Fatigue and sleep quality",
                "Terrain, incline, and footwear",
                "Age-related changes in stride mechanics"
            ],
            tips: [
                "Add 5–10 minutes of brisk walking daily — even small pace increases compound over weeks.",
                "Walk to music around 120 BPM to naturally sync your cadence to a faster rhythm.",
                "Uphill walking and stair climbing build leg power that translates directly to faster flat-ground speed.",
                "Interval walking (30s fast, 60s normal) trains your cardiovascular system more effectively than steady-pace walks."
            ]
        ),
        GaitMetricConfig(
            id: "stride",
            title: "Step Length",
            systemImage: "arrow.forward",
            unit: "cm",
            higherIsBetter: true,
            format: { "\(Int($0.rounded())) cm" },
            values: { $0.stepLengthCm },
            statusOf: {
                if $0 >= 68 { return .good }
                if $0 >= 58 { return .notice }
                return .attention
            },
            goodThresholdRaw: 68,
            normalRange: "55 – 80 cm",
            explanation: "The distance your foot covers with each step. Longer strides reflect stronger hip flexors, better flexibility, and good neuromuscular coordination. Fatigue, pain, or poor balance typically cause shorter, more shuffled steps.",
            whatAffects: [
                "Hip flexor and hamstring flexibility",
                "Glute and quad strength",
                "Walking speed (faster pace = longer steps)",
                "Pain or discomfort in lower body",
                "Height and natural leg length"
            ],
            tips: [
                "Hip flexor stretches before walks directly unlock stride length — try 30 seconds each side.",
                "Practice exaggerated strides in short bursts: 20 long steps, 20 normal. Repeat 3–4 times.",
                "Core and glute exercises (planks, bridges) provide the pelvic stability needed for a full stride.",
                "Walk slightly faster — speed and stride length are tightly linked and improve together."
            ]
        ),
        GaitMetricConfig(
            id: "support",
            title: "Double Support",
            systemImage: "figure.stand",
            unit: "%",
            higherIsBetter: false,
            format: { String(format: "%.0f%%", $0) },
            values: { $0.doubleSupportPct },
            statusOf: {
                if $0 < 21 { return .good }
                if $0 < 26 { return .notice }
                return .attention
            },
            goodThresholdRaw: 21,
            normalRange: "18 – 26%",
            explanation: "The percentage of your walking cycle where both feet are on the ground at the same time. A lower value indicates a more fluid, confident, and efficient gait. People instinctively spend more time in double support when walking carefully on unfamiliar or unstable ground.",
            whatAffects: [
                "Balance confidence and proprioception",
                "Walking speed — faster pace reduces double support naturally",
                "Surface texture and stability",
                "Age and fear of falling",
                "Footwear and terrain"
            ],
            tips: [
                "Single-leg balance exercises (standing on one foot for 30s) build the stability that reduces double support.",
                "Heel-to-toe walking in a straight line is a classic drill for improving gait fluency.",
                "Walking on slightly uneven surfaces like grass or gentle trails trains your balance systems.",
                "Lower double support often improves automatically as your overall walking speed increases."
            ]
        ),
        GaitMetricConfig(
            id: "asymmetry",
            title: "Step Asymmetry",
            systemImage: "arrow.left.arrow.right",
            unit: "%",
            higherIsBetter: false,
            format: { String(format: "%.0f%%", $0) },
            values: { $0.asymmetryPct },
            statusOf: {
                if $0 < 6  { return .good }
                if $0 < 11 { return .notice }
                return .attention
            },
            goodThresholdRaw: 6,
            normalRange: "2 – 8%",
            explanation: "The difference in timing between your left and right steps. Close to 0% is ideal — it means both sides of your body are working equally. A higher value often indicates that one leg is compensating for discomfort, weakness, or stiffness on the other side.",
            whatAffects: [
                "Hip, knee, or ankle injury or stiffness",
                "Dominant-side compensation patterns",
                "Muscle imbalances between left and right",
                "Pain avoidance and protective gait",
                "Footwear differences or uneven sole wear"
            ],
            tips: [
                "Foam roll your tighter side before walks to release tension that causes asymmetric loading.",
                "If one side is consistently favored, a physiotherapist can identify the root cause quickly — often hip or ankle stiffness.",
                "Single-leg exercises (lunges, step-ups) on your weaker side can help equalize strength over time.",
                "Most asymmetry under 11% is within normal variation; only sustained values above this warrant professional attention."
            ]
        )
    ]
}

// MARK: - Section

struct GaitHealthSection: View {
    private var service      = GaitHealthService.shared
    @State private var selectedConfig: GaitMetricConfig? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Walking Health", systemImage: "waveform.path.ecg")
                    .font(.headline)
                    .foregroundColor(.earthCream)
                Spacer()
                if service.isLoading {
                    ProgressView().scaleEffect(0.75).tint(.earthGreen)
                }
            }
            .padding(.horizontal, 20)

            if !service.isLoading && !service.hasAnyData {
                emptyState
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 12
                ) {
                    ForEach(GaitMetricConfig.all) { config in
                        GaitMetricCard(
                            config:    config,
                            snapshots: service.snapshots,
                            onTap:     { selectedConfig = config }
                        )
                    }
                }
                .padding(.horizontal, 20)
            }

            Text("Measured by iPhone sensors during detected walking bouts. Tap a card for details.")
                .font(.caption2)
                .foregroundColor(.earthMuted.opacity(0.55))
                .padding(.horizontal, 20)
        }
        .task {
            if service.snapshots.isEmpty { await service.load() }
        }
        .sheet(item: $selectedConfig) { config in
            GaitMetricDetailSheet(config: config, snapshots: service.snapshots)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 14) {
            Image(systemName: "figure.walk")
                .font(.title2)
                .foregroundColor(.earthMuted)
            VStack(alignment: .leading, spacing: 4) {
                Text("No gait data yet")
                    .font(.subheadline.bold())
                    .foregroundColor(.earthCream)
                Text("Walk with your iPhone to start tracking walking health metrics.")
                    .font(.caption)
                    .foregroundColor(.earthMuted)
            }
            Spacer()
        }
        .padding(16)
        .background(Color.earthCard)
        .cornerRadius(14)
        .padding(.horizontal, 20)
    }
}

// MARK: - Metric Card

private struct GaitMetricCard: View {
    let config:    GaitMetricConfig
    let snapshots: [GaitDaySnapshot]
    let onTap:     () -> Void

    private struct Pt: Identifiable { let id: Int; let value: Double }

    private var chartPts: [Pt] {
        snapshots.enumerated().compactMap { i, s in
            guard let v = config.values(s) else { return nil }
            return Pt(id: i, value: v)
        }
    }

    private var recent7: [Double] { snapshots.suffix(7).compactMap { config.values($0) } }
    private var prior7:  [Double] { snapshots.dropLast(7).suffix(7).compactMap { config.values($0) } }

    private var currentAvg: Double? {
        recent7.isEmpty ? nil : recent7.reduce(0, +) / Double(recent7.count)
    }

    private var trendPct: Double? {
        guard let cur = currentAvg, !prior7.isEmpty else { return nil }
        let prev = prior7.reduce(0, +) / Double(prior7.count)
        guard prev > 0 else { return nil }
        return (cur - prev) / prev * 100
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: config.systemImage)
                        .font(.caption)
                        .foregroundColor(.earthGreen)
                    Text(config.title)
                        .font(.caption.bold())
                        .foregroundColor(.earthCream)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.earthMuted.opacity(0.4))
                }

                if let cur = currentAvg {
                    Text(config.format(cur))
                        .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundColor(.earthCream)

                    HStack(spacing: 6) {
                        let st = config.statusOf(cur)
                        Label(st.label, systemImage: st.icon)
                            .font(.caption2.bold())
                            .foregroundColor(st.color)
                        Spacer()
                        if let t = trendPct { trendBadge(t) }
                    }
                } else {
                    Text("–")
                        .font(.title3.bold())
                        .foregroundColor(.earthMuted)
                        .padding(.bottom, 2)
                }

                if !chartPts.isEmpty { sparkline }
            }
            .padding(12)
            .background(Color.earthCard)
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }

    private func trendBadge(_ pct: Double) -> some View {
        let isUp   = pct >= 0
        let isGood = config.higherIsBetter ? isUp : !isUp
        return HStack(spacing: 2) {
            Image(systemName: isUp ? "arrow.up" : "arrow.down")
            Text(String(format: "%.0f%%", abs(pct)))
        }
        .font(.caption2.bold())
        .foregroundColor(isGood ? .earthGreen : .earthOrange)
    }

    private var sparkline: some View {
        Chart {
            ForEach(chartPts) { pt in
                AreaMark(x: .value("Day", pt.id), y: .value("Value", pt.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(
                        colors: [Color.earthGreen.opacity(0.28), .clear],
                        startPoint: .top, endPoint: .bottom
                    ))
            }
            ForEach(chartPts) { pt in
                LineMark(x: .value("Day", pt.id), y: .value("Value", pt.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.earthGreen.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 38)
    }
}

// MARK: - Detail Sheet

struct GaitMetricDetailSheet: View {
    let config:    GaitMetricConfig
    let snapshots: [GaitDaySnapshot]

    @Environment(\.dismiss) private var dismiss

    // Computed statistics
    private var allValues:   [Double] { snapshots.compactMap { config.values($0) } }
    private var recent7:     [Double] { snapshots.suffix(7).compactMap { config.values($0) } }
    private var prior7:      [Double] { snapshots.dropLast(7).suffix(7).compactMap { config.values($0) } }

    private var sevenDayAvg: Double? {
        recent7.isEmpty ? nil : recent7.reduce(0, +) / Double(recent7.count)
    }
    private var thirtyDayAvg: Double? {
        allValues.isEmpty ? nil : allValues.reduce(0, +) / Double(allValues.count)
    }
    private var bestValue: Double? {
        config.higherIsBetter ? allValues.max() : allValues.min()
    }
    private var trendPct: Double? {
        guard let cur = sevenDayAvg, !prior7.isEmpty else { return nil }
        let prev = prior7.reduce(0, +) / Double(prior7.count)
        guard prev > 0 else { return nil }
        return (cur - prev) / prev * 100
    }
    private var currentStatus: GaitStatus? {
        sevenDayAvg.map { config.statusOf($0) }
    }

    // Day-of-week averages (0 = Sunday … 6 = Saturday)
    private var dowAverages: [(weekday: Int, label: String, value: Double)] {
        let cal     = Calendar.current
        var buckets = [Int: (Double, Int)]()
        for snap in snapshots {
            guard let v = config.values(snap) else { continue }
            let wd = cal.component(.weekday, from: snap.date) - 1
            let (s, c) = buckets[wd] ?? (0, 0)
            buckets[wd] = (s + v, c + 1)
        }
        let labels = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
        return (0..<7).compactMap { i in
            guard let (sum, count) = buckets[i] else { return nil }
            return (i, labels[i], sum / Double(count))
        }
    }

    // Chart data
    private struct ChartPt: Identifiable {
        let id: Int; let date: Date; let value: Double
    }
    private var chartPts: [ChartPt] {
        snapshots.enumerated().compactMap { i, s in
            guard let v = config.values(s) else { return nil }
            return ChartPt(id: i, date: s.date, value: v)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        heroHeader
                        if !chartPts.isEmpty { trendChartSection }
                        statsGrid
                        if !dowAverages.isEmpty { dowSection }
                        aboutSection
                        affectsSection
                        tipsSection
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle(config.title)
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

    // MARK: Hero header

    private var heroHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.earthGreen.opacity(0.12))
                    .frame(width: 56, height: 56)
                Image(systemName: config.systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.earthGreen)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let avg = sevenDayAvg {
                    Text(config.format(avg))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.earthCream)
                    HStack(spacing: 8) {
                        if let st = currentStatus {
                            Label(st.label, systemImage: st.icon)
                                .font(.caption.bold())
                                .foregroundColor(st.color)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(st.color.opacity(0.12))
                                .cornerRadius(8)
                        }
                        if let t = trendPct {
                            let isGood = (config.higherIsBetter && t >= 0) || (!config.higherIsBetter && t <= 0)
                            Label(String(format: "%+.1f%% vs prior week", t), systemImage: t >= 0 ? "arrow.up" : "arrow.down")
                                .font(.caption2)
                                .foregroundColor(isGood ? .earthGreen : .earthOrange)
                        }
                    }
                } else {
                    Text("No data yet")
                        .font(.title3.bold())
                        .foregroundColor(.earthMuted)
                }
                Text("7-day average · Normal: \(config.normalRange)")
                    .font(.caption2)
                    .foregroundColor(.earthMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: Trend chart

    private var trendChartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("30-Day Trend")
                .font(.subheadline.bold())
                .foregroundColor(.earthCream)
                .padding(.horizontal, 20)

            Chart {
                // Area fill
                ForEach(chartPts) { pt in
                    AreaMark(x: .value("Day", pt.date), y: .value("Value", pt.value))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(
                            colors: [Color.earthGreen.opacity(0.22), .clear],
                            startPoint: .top, endPoint: .bottom
                        ))
                }
                // Line
                ForEach(chartPts) { pt in
                    LineMark(x: .value("Day", pt.date), y: .value("Value", pt.value))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Color.earthGreen.opacity(0.9))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                // Colored dots per status
                ForEach(chartPts) { pt in
                    PointMark(x: .value("Day", pt.date), y: .value("Value", pt.value))
                        .foregroundStyle(config.statusOf(pt.value).color)
                        .symbolSize(18)
                }
                // "Good" threshold reference line
                RuleMark(y: .value("Good", config.goodThresholdRaw))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    .foregroundStyle(Color.earthGreen.opacity(0.45))
                    .annotation(position: .trailing, alignment: .center) {
                        Text("Good")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.earthGreen.opacity(0.7))
                    }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine().foregroundStyle(Color.earthMuted.opacity(0.1))
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.earthMuted)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.earthMuted.opacity(0.1))
                    AxisValueLabel {
                        if let d = value.as(Double.self) {
                            Text(config.format(d))
                                .font(.system(size: 9))
                                .foregroundStyle(Color.earthMuted)
                        }
                    }
                }
            }
            .frame(height: 180)
            .padding(.horizontal, 20)
        }
    }

    // MARK: Stats grid

    private var statsGrid: some View {
        let items: [(label: String, value: String?, note: String)] = [
            ("7-Day Avg",  sevenDayAvg.map  { config.format($0) }, "this week"),
            ("30-Day Avg", thirtyDayAvg.map { config.format($0) }, "last 30 days"),
            ("Personal Best", bestValue.map { config.format($0) }, config.higherIsBetter ? "highest recorded" : "lowest recorded"),
            ("Trend",      trendPct.map { String(format: "%+.1f%%", $0) }, "vs prior 7 days")
        ]

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.label)
                        .font(.caption2.bold())
                        .foregroundColor(.earthMuted)
                    Text(item.value ?? "–")
                        .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundColor(.earthCream)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text(item.note)
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

    // MARK: Day-of-week

    private var dowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Day-of-Week Pattern")
                .font(.subheadline.bold())
                .foregroundColor(.earthCream)

            let maxVal = dowAverages.map(\.value).max() ?? 1
            let minVal = dowAverages.map(\.value).min() ?? 0

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(dowAverages, id: \.weekday) { entry in
                    let normalized = maxVal > minVal
                        ? (entry.value - minVal) / (maxVal - minVal)
                        : 0.5
                    VStack(spacing: 4) {
                        Text(config.format(entry.value))
                            .font(.system(size: 8, weight: .medium).monospacedDigit())
                            .foregroundColor(.earthMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(config.statusOf(entry.value).color.opacity(0.75))
                            .frame(height: max(12, 60 * normalized))
                        Text(entry.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.earthMuted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 90, alignment: .bottom)
        }
        .padding(16)
        .background(Color.earthCard)
        .cornerRadius(16)
        .padding(.horizontal, 20)
    }

    // MARK: About

    private var aboutSection: some View {
        infoSection(title: "About This Metric", icon: "info.circle.fill", color: Color(red: 0.42, green: 0.52, blue: 0.88)) {
            Text(config.explanation)
                .font(.subheadline)
                .foregroundColor(.earthMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: What Affects

    private var affectsSection: some View {
        infoSection(title: "What Affects It", icon: "chart.bar.fill", color: .earthOrange) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(config.whatAffects, id: \.self) { item in
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
    }

    // MARK: Tips

    private var tipsSection: some View {
        infoSection(title: "How to Improve", icon: "lightbulb.fill", color: .earthGreen) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(config.tips.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.earthGreen.opacity(0.15))
                                .frame(width: 24, height: 24)
                            Text("\(i + 1)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.earthGreen)
                        }
                        Text(config.tips[i])
                            .font(.subheadline)
                            .foregroundColor(.earthMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Section layout helper

    private func infoSection<Content: View>(
        title: String,
        icon: String,
        color: Color,
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
}
