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
        let start = cal.date(byAdding: .day, value: -29, to: today) ?? today
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
        case .notice:    return Color.accentNotice
        case .attention: return .earthOrange
        }
    }

    var symbol: WktSymbol {
        switch self {
        case .good:      return .success
        case .notice:    return .dotted
        case .attention: return .warning
        }
    }

    /// circle.dotted has no fill variant; the other two are drawn filled.
    var filled: Bool { self != .notice }

    /// String form for RecoveryCard (RecoveryViews), whose readiness badge
    /// takes a model-supplied symbol name.
    var icon: String { symbol.name + (filled ? ".fill" : "") }
}

// MARK: - Metric Config

struct GaitMetricConfig: Identifiable {
    let id: String
    let title: String
    let symbol: WktSymbol
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

    // Walking speed and step length follow the phone's units, like distance and
    // pace everywhere else; they were metric-only until 2026-10-07. Health
    // stores metres per second and centimetres, and the status thresholds stay
    // in those units — only the words change.
    static func speedText(_ mps: Double, usesMiles: Bool) -> String {
        usesMiles ? String(format: "%.1f mph", mps * 2.236_936)
                  : String(format: "%.1f km/h", mps * 3.6)
    }

    static func stepLengthText(_ cm: Double, usesMiles: Bool) -> String {
        usesMiles ? "\(Int((cm / 2.54).rounded())) in" : "\(Int(cm.rounded())) cm"
    }

    private static var usesMiles: Bool { Locale.current.measurementSystem == .us }

    static let all: [GaitMetricConfig] = [
        GaitMetricConfig(
            id: "speed",
            title: "Walking speed",
            symbol: .walkMotion,
            unit: usesMiles ? "mph" : "km/h",
            higherIsBetter: true,
            format: { speedText($0, usesMiles: usesMiles) },
            values: { $0.speedMps },
            statusOf: {
                let kmh = $0 * 3.6
                if kmh >= 4.0 { return .good }
                if kmh >= 3.2 { return .notice }
                return .attention
            },
            goodThresholdRaw: 4.0 / 3.6,   // 4.0 km/h in m/s
            normalRange: usesMiles ? "2.2 – 3.4 mph" : "3.5 – 5.5 km/h",
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
            title: "Step length",
            symbol: .cadenceArrow,
            unit: usesMiles ? "in" : "cm",
            higherIsBetter: true,
            format: { stepLengthText($0, usesMiles: usesMiles) },
            values: { $0.stepLengthCm },
            statusOf: {
                if $0 >= 68 { return .good }
                if $0 >= 58 { return .notice }
                return .attention
            },
            goodThresholdRaw: 68,
            normalRange: usesMiles ? "22 – 31 in" : "55 – 80 cm",
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
            title: "Double support",
            symbol: .balanceFigure,
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
            title: "Step asymmetry",
            symbol: .strideWidth,
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
    private var service = GaitHealthService.shared
    @State private var selectedConfigId: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: WktSpacing.betweenCards) {
            // WktSectionHeader's look, with a spinner where its link would be.
            HStack(alignment: .firstTextBaseline) {
                Text("Walking health")
                    .font(.wktSection)
                    .foregroundColor(.earthCream)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if service.isLoading {
                    ProgressView().scaleEffect(0.75).tint(.earthGreen)
                }
            }

            if !service.isLoading && !service.hasAnyData {
                emptyState
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: WktSpacing.betweenCards), count: 2),
                    spacing: WktSpacing.betweenCards
                ) {
                    ForEach(GaitMetricConfig.all) { config in
                        GaitMetricCard(
                            config:    config,
                            snapshots: service.snapshots,
                            onTap:     { selectedConfigId = config.id }
                        )
                    }
                }
            }

            Text("Measured by iPhone sensors during detected walking bouts. Tap a card for details.")
                .font(.wktLabel)
                .foregroundColor(.earthMuted)
        }
        .task {
            if service.snapshots.isEmpty { await service.load() }
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedConfigId != nil },
            set: { if !$0 { selectedConfigId = nil } }
        )) {
            if let id = selectedConfigId,
               let config = GaitMetricConfig.all.first(where: { $0.id == id }) {
                GaitMetricDetailContentView(config: config, snapshots: service.snapshots)
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            WktIconBadge(symbol: .walk, tint: .earthMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text("No gait data yet")
                    .font(.wktRowTitle)
                    .foregroundColor(.earthCream)
                Text("Walk with your iPhone to start tracking walking health metrics.")
                    .font(.wktLabel)
                    .foregroundColor(.earthMuted)
            }
            Spacer()
        }
        .wktCard()
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
                HStack(spacing: 8) {
                    WktIconBadge(symbol: config.symbol)
                    Spacer()
                    Image(wkt: .chevronRight)
                        .wktIcon(.inline, tint: .earthMuted)
                }
                Text(config.title)
                    .font(.wktLabel)
                    .foregroundColor(.earthMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if let cur = currentAvg {
                    Text(config.format(cur))
                        .font(.wktRowTitle.monospacedDigit())
                        .foregroundColor(.earthCream)

                    HStack(spacing: 6) {
                        let st = config.statusOf(cur)
                        WktStatusChip(text: st.label, dot: st.color)
                        Spacer(minLength: 0)
                        if let t = trendPct { trendBadge(t) }
                    }
                } else {
                    Text("–")
                        .font(.wktCardTitle)
                        .foregroundColor(.earthMuted)
                }

                if !chartPts.isEmpty { sparkline }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .wktCard(padding: 14)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.97))
        .accessibilityElement(children: .combine)
    }

    private func trendBadge(_ pct: Double) -> some View {
        let isUp   = pct >= 0
        let isGood = config.higherIsBetter ? isUp : !isUp
        return HStack(spacing: 2) {
            Image(wkt: isUp ? .arrowUp : .arrowDown)
            Text(String(format: "%.0f%%", abs(pct)))
        }
        .font(.wktLabel)
        .foregroundColor(isGood ? .earthGreen : .earthOrange)
        .lineLimit(1)
        .fixedSize()
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

// MARK: - Detail Content (push-safe: no NavigationStack, no Done button)

struct GaitMetricDetailContentView: View {
    let config:    GaitMetricConfig
    let snapshots: [GaitDaySnapshot]

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
        ZStack {
            Color.earthBg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                    heroHeader
                    if !chartPts.isEmpty { trendChartSection }
                    statsGrid
                    if !dowAverages.isEmpty { dowSection }
                    aboutSection
                    affectsSection
                    tipsSection
                }
                .padding(.horizontal, WktSpacing.screen)
                .padding(.top, 8)
                .padding(.bottom, WktSpacing.betweenSections)
            }
        }
        .navigationTitle(config.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Hero header

    private var heroHeader: some View {
        WktMetricHero(
            badge: WktIconBadge(symbol: config.symbol, size: 48),
            value: sevenDayAvg.map { config.format($0) } ?? "No data yet",
            valueColor: sevenDayAvg == nil ? .earthMuted : .earthCream,
            subtitle: "7-day average · Normal: \(config.normalRange)"
        ) {
            if let st = currentStatus {
                WktStatusChip(text: st.label, dot: st.color)
            }
            if let t = trendPct {
                let isGood = (config.higherIsBetter && t >= 0) || (!config.higherIsBetter && t <= 0)
                WktStatusChip(text: String(format: "%+.1f%% vs prior week", t),
                              textColor: isGood ? .earthGreen : .earthOrange) {
                    Image(wkt: t >= 0 ? .arrowUp : .arrowDown)
                        .wktIcon(.inline, tint: isGood ? .earthGreen : .earthOrange)
                }
            }
        }
    }

    // MARK: Trend chart

    private var trendChartSection: some View {
        WktSection(title: "30-day trend") {
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
                            .font(.wktBody(9))
                            .foregroundColor(.earthGreen.opacity(0.7))
                    }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine().foregroundStyle(Color.earthTrack)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                        .font(.wktBody(9))
                        .foregroundStyle(Color.earthMuted)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.earthTrack)
                    AxisValueLabel {
                        if let d = value.as(Double.self) {
                            Text(config.format(d))
                                .font(.wktBody(9))
                                .foregroundStyle(Color.earthMuted)
                        }
                    }
                }
            }
            .frame(height: 180)
            .wktCard()
        }
    }

    // MARK: Stats grid

    private var statsGrid: some View {
        WktStatGrid(items: [
            .init(label: "7-day avg", value: sevenDayAvg.map { config.format($0) } ?? "–", note: "this week"),
            .init(label: "30-day avg", value: thirtyDayAvg.map { config.format($0) } ?? "–", note: "last 30 days"),
            .init(label: "Personal best", value: bestValue.map { config.format($0) } ?? "–",
                  note: config.higherIsBetter ? "highest recorded" : "lowest recorded"),
            .init(label: "Trend", value: trendPct.map { String(format: "%+.1f%%", $0) } ?? "–",
                  note: "vs prior 7 days")
        ])
    }

    // MARK: Day-of-week

    private var dowSection: some View {
        WktSection(title: "Day-of-week pattern") {
            let maxVal = dowAverages.map(\.value).max() ?? 1
            let minVal = dowAverages.map(\.value).min() ?? 0

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(dowAverages, id: \.weekday) { entry in
                    let normalized = maxVal > minVal
                        ? (entry.value - minVal) / (maxVal - minVal)
                        : 0.5
                    VStack(spacing: 4) {
                        Text(config.format(entry.value))
                            .font(.wktBody(9).monospacedDigit())
                            .foregroundColor(.earthMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Capsule()
                            .fill(config.statusOf(entry.value).color)
                            .frame(height: max(12, 60 * normalized))
                            .frame(maxWidth: 22)
                        Text(entry.label)
                            .font(.wktLabel)
                            .foregroundColor(.earthMuted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 90, alignment: .bottom)
            .wktCard()
        }
    }

    // MARK: About

    private var aboutSection: some View {
        WktInfoSection(title: "About this metric") {
            Text(config.explanation)
                .font(.wktBodyText)
                .foregroundColor(.earthMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: What Affects

    private var affectsSection: some View {
        WktInfoSection(title: "What affects it") {
            WktBulletList(items: config.whatAffects)
        }
    }

    // MARK: Tips

    private var tipsSection: some View {
        WktInfoSection(title: "How to improve") {
            WktNumberedList(items: config.tips)
        }
    }
}

// MARK: - Detail Sheet (thin wrapper — keeps existing sheet callers compiling)

struct GaitMetricDetailSheet: View {
    let config:    GaitMetricConfig
    let snapshots: [GaitDaySnapshot]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GaitMetricDetailContentView(config: config, snapshots: snapshots)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }.foregroundColor(.earthGreen)
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
