import HealthKit
import SwiftUI

// MARK: - Readiness Level

enum ReadinessLevel: Equatable {
    case push       // HRV above baseline + solid sleep
    case active     // Normal readiness
    case recover    // Low HRV or poor sleep
    case unknown    // Insufficient data

    var label: String {
        switch self {
        case .push:    return "Push"
        case .active:  return "Active"
        case .recover: return "Recover"
        case .unknown: return "–"
        }
    }

    var color: Color {
        switch self {
        case .push:    return .earthGreen
        case .active:  return Color.accentNotice
        case .recover: return .earthOrange
        case .unknown: return .earthMuted
        }
    }

    var icon: String {
        switch self {
        case .push:    return "bolt.fill"
        case .active:  return "checkmark.circle.fill"
        case .recover: return "moon.zzz.fill"
        case .unknown: return "minus.circle"
        }
    }
}

// MARK: - History Entry

struct RecoveryEntry: Identifiable {
    let id: Date
    let date: Date
    let value: Double
}

// MARK: - Service

@Observable
final class RecoveryService {
    static let shared = RecoveryService()

    // Today's summary values
    var sleepHours:      Double?          // decimal hours from last night
    var hrv:             Double?          // latest SDNN in ms, last 48 hours only
    var hrvBaseline:     Double?          // 30-day personal avg SDNN
    var hrvBaselineDays                  = 0  // days with HRV inside that 30-day window
    var restingHR:       Double?          // bpm
    var activeCal:       Double?          // kcal burned today
    var walkingHR:       Double?          // avg walking HR in bpm
    var flightsClimbed:  Int?             // today
    var readiness:       ReadinessLevel  = .unknown
    var readinessHint                    = "No sleep or HRV data yet"   // what the level rests on, or what is missing
    var isLoading                        = false

    // 30-day history (for detail sheets)
    var sleepHistory: [RecoveryEntry]    = []   // one entry per night
    var hrvHistory:   [RecoveryEntry]    = []   // daily average SDNN
    var calHistory:   [RecoveryEntry]    = []   // daily active kcal

    var sleepFormatted: String? { sleepHours.map { Self.formatHours($0) } }

    static var readTypes: Set<HKObjectType> {
        [
            HKCategoryType(.sleepAnalysis),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.walkingHeartRateAverage),
            HKQuantityType(.flightsClimbed)
        ]
    }

    private let store = HKHealthStore()

    func load() async {
        guard HKHealthStore.isHealthDataAvailable(), !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        async let sleep      = fetchSleepLastNight()
        let now = Date()
        async let h          = fetchLatestSample(.heartRateVariabilitySDNN, unit: HKUnit(from: "ms"),
                                                 since: now.addingTimeInterval(-ReadinessEvaluator.hrvFreshness))
        async let rhr        = fetchLatest(.restingHeartRate,          unit: .count().unitDivided(by: .minute()))
        async let cal        = fetchTodaySum(.activeEnergyBurned,      unit: .kilocalorie())
        async let whr        = fetchLatest(.walkingHeartRateAverage,   unit: .count().unitDivided(by: .minute()))
        async let flights    = fetchTodaySum(.flightsClimbed,          unit: .count())
        async let base       = fetch30dAvg(.heartRateVariabilitySDNN,  unit: HKUnit(from: "ms"))
        async let sleepHist  = fetchSleepHistory()
        async let hrvHist    = fetchDailyHistory(.heartRateVariabilitySDNN, unit: HKUnit(from: "ms"), options: .discreteAverage)
        async let calHist    = fetchDailyHistory(.activeEnergyBurned,       unit: .kilocalorie(),     options: .cumulativeSum)

        let (s, hv, r, c, w, f, b, sh, hh, ch) = await (sleep, h, rhr, cal, whr, flights, base, sleepHist, hrvHist, calHist)

        sleepHours     = s
        hrv            = hv?.value
        restingHR      = r
        activeCal      = c
        walkingHR      = w
        flightsClimbed = f.map { Int($0) }
        hrvBaseline    = b
        // Days inside the baseline's own rolling 30 days; the history starts a day earlier.
        hrvBaselineDays = hh.filter { $0.date >= now.addingTimeInterval(-30 * 86_400) }.count
        let result     = ReadinessEvaluator.evaluate(ReadinessInputs(
            sleepHours: s, hrv: hv?.value, hrvDate: hv?.date, baseline: b, baselineReadings: hrvBaselineDays
        ), now: now)
        readiness      = result.level
        readinessHint  = result.hint
        sleepHistory   = sh
        hrvHistory     = hh
        calHistory     = ch
    }

    // MARK: - Sleep — last night

    private func fetchSleepLastNight() async -> Double? {
        let cal    = Calendar.current
        let today  = cal.startOfDay(for: Date())
        let yest   = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let wStart = cal.date(bySettingHour: 17, minute: 0, second: 0, of: yest) ?? yest
        let wEnd   = cal.date(bySettingHour: 12, minute: 0, second: 0, of: today) ?? today
        let pred   = HKQuery.predicateForSamples(withStart: wStart, end: wEnd)

        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(
                sampleType: HKCategoryType(.sleepAnalysis),
                predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, _ in
                guard let all = samples as? [HKCategorySample], !all.isEmpty else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: Self.sumAsleepSeconds(all) / 3600)
            }
            self.store.execute(q)
        }
    }

    // MARK: - Sleep — 30-night history

    private func fetchSleepHistory() async -> [RecoveryEntry] {
        let cal    = Calendar.current
        let today  = cal.startOfDay(for: Date())
        let start  = cal.date(byAdding: .day, value: -31, to: today) ?? today
        let pred   = HKQuery.predicateForSamples(withStart: start, end: Date())

        return await withCheckedContinuation { cont in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(
                sampleType: HKCategoryType(.sleepAnalysis),
                predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]
            ) { _, samples, _ in
                guard let all = samples as? [HKCategorySample] else {
                    cont.resume(returning: []); return
                }
                let asleepVals = Self.asleepValueSet
                let asleep     = all.filter { asleepVals.contains($0.value) }

                // Bucket samples by sleep night: determined by endDate.
                // Samples ending before noon are assigned to the previous calendar day.
                var buckets: [Date: [(Date, Date)]] = [:]
                for s in asleep {
                    let endDay  = cal.startOfDay(for: s.endDate)
                    let endHour = cal.component(.hour, from: s.endDate)
                    let night   = endHour < 12
                        ? cal.date(byAdding: .day, value: -1, to: endDay) ?? endDay
                        : endDay
                    buckets[night, default: []].append((s.startDate, s.endDate))
                }

                let entries: [RecoveryEntry] = buckets.compactMap { (night, ivs) in
                    let hours = Self.mergeAndSum(ivs) / 3600
                    guard hours > 0 else { return nil }
                    return RecoveryEntry(id: night, date: night, value: hours)
                }.sorted { $0.date < $1.date }

                cont.resume(returning: entries)
            }
            self.store.execute(q)
        }
    }

    // MARK: - Quantity history (HRV, calories)

    private func fetchDailyHistory(
        _ id: HKQuantityTypeIdentifier,
        unit: HKUnit,
        options: HKStatisticsOptions,
        days: Int = 30
    ) async -> [RecoveryEntry] {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -days, to: today) ?? today
        let pred  = HKQuery.predicateForSamples(withStart: start, end: Date())

        return await withCheckedContinuation { cont in
            let q = HKStatisticsCollectionQuery(
                quantityType: HKQuantityType(id),
                quantitySamplePredicate: pred,
                options: options,
                anchorDate: start,
                intervalComponents: DateComponents(day: 1)
            )
            q.initialResultsHandler = { _, results, _ in
                var out: [RecoveryEntry] = []
                results?.enumerateStatistics(from: start, to: Date()) { stat, _ in
                    let v: Double?
                    if options.contains(.discreteAverage) {
                        v = stat.averageQuantity()?.doubleValue(for: unit)
                    } else {
                        v = stat.sumQuantity()?.doubleValue(for: unit)
                    }
                    guard let v else { return }
                    let day = cal.startOfDay(for: stat.startDate)
                    out.append(RecoveryEntry(id: day, date: day, value: v))
                }
                cont.resume(returning: out)
            }
            self.store.execute(q)
        }
    }

    // MARK: - Point queries

    private func fetchLatest(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        await fetchLatestSample(id, unit: unit, since: nil)?.value
    }

    /// The latest sample and its end date; with `since`, only samples from then on.
    private func fetchLatestSample(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                                   since: Date?) async -> (value: Double, date: Date)? {
        let pred = since.map { HKQuery.predicateForSamples(withStart: $0, end: nil) }
        return await withCheckedContinuation { cont in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let q = HKSampleQuery(
                sampleType: HKQuantityType(id), predicate: pred, limit: 1, sortDescriptors: [sort]
            ) { _, s, _ in
                let sample = s?.first as? HKQuantitySample
                cont.resume(returning: sample.map { ($0.quantity.doubleValue(for: unit), $0.endDate) })
            }
            store.execute(q)
        }
    }

    private func fetchTodaySum(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        let start = Calendar.current.startOfDay(for: Date())
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(
                quantityType: HKQuantityType(id),
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: Date()),
                options: .cumulativeSum
            ) { _, r, _ in cont.resume(returning: r?.sumQuantity()?.doubleValue(for: unit)) }
            store.execute(q)
        }
    }

    private func fetch30dAvg(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        let start = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(
                quantityType: HKQuantityType(id),
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: Date()),
                options: .discreteAverage
            ) { _, r, _ in cont.resume(returning: r?.averageQuantity()?.doubleValue(for: unit)) }
            store.execute(q)
        }
    }

    // MARK: - Static helpers

    // Pure data and pure functions — no actor state touched. Marked nonisolated so
    // the HealthKit query callbacks, which arrive on a background queue, can use them
    // without hopping to the main actor (SWIFT_DEFAULT_ACTOR_ISOLATION is MainActor).
    nonisolated static let asleepValueSet: Set<Int> = [
        HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        HKCategoryValueSleepAnalysis.asleepCore.rawValue,
        HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
        HKCategoryValueSleepAnalysis.asleepREM.rawValue
    ]

    nonisolated static func sumAsleepSeconds(_ samples: [HKCategorySample]) -> Double {
        let ivs = samples
            .filter { asleepValueSet.contains($0.value) }
            .map { ($0.startDate, $0.endDate) }
            .sorted { $0.0 < $1.0 }
        return mergeAndSum(ivs)
    }

    nonisolated static func mergeAndSum(_ ivs: [(Date, Date)]) -> Double {
        var merged: [(Date, Date)] = []
        for iv in ivs {
            if let last = merged.last, iv.0 <= last.1 {
                merged[merged.count - 1] = (last.0, max(last.1, iv.1))
            } else {
                merged.append(iv)
            }
        }
        return merged.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) }
    }

    nonisolated static func formatHours(_ h: Double) -> String {
        let hrs = Int(h)
        let min = Int((h - Double(hrs)) * 60)
        return hrs > 0 ? "\(hrs)h \(min)m" : "\(min)m"
    }
}
