import SwiftUI
import Combine
import HealthKit
import CoreMotion
import UserNotifications

// MARK: - Calendar Day Model

struct CalendarDay: Identifiable {
    let id: Date
    let date: Date
    let weekday: Int
    let goal: Int
    let steps: Int?
    let tag: String?
    let tagEmoji: String?
    let tagColor: Color?

    var isToday: Bool  { Calendar.current.isDateInToday(date) }
    var isFuture: Bool { date > Calendar.current.startOfDay(for: Date()) && !isToday }
    var progress: Double {
        guard let s = steps else { return 0 }
        return min(1.0, Double(s) / Double(max(1, goal)))
    }
    var goalMet: Bool? {
        guard let s = steps, !isFuture else { return nil }
        return s >= goal
    }
}

// MARK: - Activity Tag Config

struct ActivityTagConfig: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var emoji: String
    var colorIndex: Int

    static let palette: [Color] = [
        Color(red: 0.40, green: 0.60, blue: 0.90),  // blue
        Color(red: 0.35, green: 0.65, blue: 0.45),  // green
        Color(red: 0.90, green: 0.45, blue: 0.20),  // orange
        Color(red: 0.62, green: 0.45, blue: 0.30),  // brown
        Color(red: 0.85, green: 0.30, blue: 0.30),  // red
        Color(red: 0.55, green: 0.35, blue: 0.80),  // purple
    ]

    var color: Color { Self.palette[colorIndex % Self.palette.count] }

    static let defaults: [ActivityTagConfig] = [
        ActivityTagConfig(id: "Rest",   name: "Rest",   emoji: "🛋️",  colorIndex: 0),
        ActivityTagConfig(id: "Walk",   name: "Walk",   emoji: "🚶",  colorIndex: 1),
        ActivityTagConfig(id: "Run",    name: "Run",    emoji: "🏃",  colorIndex: 2),
        ActivityTagConfig(id: "Hike",   name: "Hike",   emoji: "⛰️", colorIndex: 3),
        ActivityTagConfig(id: "Cardio", name: "Cardio", emoji: "❤️‍🔥", colorIndex: 4),
        ActivityTagConfig(id: "Bike",   name: "Bike",   emoji: "🚴", colorIndex: 5),
    ]
}

// MARK: - Step Manager

@MainActor
final class StepManager: ObservableObject {
    @Published var todaySteps: Int = 0
    @Published var todayDistanceMeters: Double = 0   // actual HealthKit walking+running distance
    @Published var trackingMode: TrackingMode = .healthKit
    @Published var isLoading = false
    @Published var permissionDenied = false

    @Published var dailyGoal: Int = 10_000 {
        didSet {
            UserDefaults.standard.set(dailyGoal, forKey: UDKey.dailyGoal)
            // Nil out unlocked weekday overrides so they inherit the new goal
            for wd in 1...7 where !lockedWeekdays.contains(wd) {
                weekdayGoals[wd] = nil
            }
        }
    }
    @Published var useCustomSchedule: Bool = false {
        didSet { UserDefaults.standard.set(useCustomSchedule, forKey: UDKey.useCustomSchedule) }
    }
    @Published var weekdayGoals: [Int: Int] = [:] {
        didSet { saveWeekdayGoals() }
    }
    @Published var lockedWeekdays: Set<Int> = [] {
        didSet { saveLockedWeekdays() }
    }
    @Published var weekdayTags: [Int: String] = [:] {
        didSet { saveWeekdayTags() }
    }
    @Published var tagConfigs: [ActivityTagConfig] = ActivityTagConfig.defaults {
        didSet { saveTagConfigs() }
    }
    @Published var historicalDayGoals: [String: Int] = [:] {
        didSet { saveHistoricalDayGoals() }
    }
    @Published var weeklyCalendar: [CalendarDay] = []

    enum TrackingMode: String, CaseIterable, Identifiable {
        case healthKit = "Apple Health"
        case appOnly   = "App Only"
        var id: String { rawValue }
    }

    private enum UDKey {
        static let dailyGoal          = "stepDailyGoal"
        static let useCustomSchedule  = "stepUseCustomSchedule"
        static let weekdayGoals       = "stepWeekdayGoals"
        static let lockedWeekdays     = "stepLockedWeekdays"
        static let weekdayTags        = "stepWeekdayTags"
        static let tagConfigs         = "stepTagConfigs"
        static let historicalDayGoals = "stepHistoricalDayGoals"
    }

    private let healthStore = HKHealthStore()
    private let pedometer   = CMPedometer()

    var currentGoal: Int {
        if useCustomSchedule {
            let wd = Calendar.current.component(.weekday, from: Date())
            return weekdayGoals[wd] ?? dailyGoal
        }
        return dailyGoal
    }

    var remainingSteps:  Int    { max(0, currentGoal - todaySteps) }
    var remainingMeters: Double {
        let goalMeters = Double(currentGoal) * 0.762
        // Prefer actual HealthKit distance; fall back to step × avg stride when not yet loaded.
        if todayDistanceMeters > 0 {
            return max(0, goalMeters - todayDistanceMeters)
        }
        return Double(remainingSteps) * 0.762
    }
    var progress:        Double { min(1.0, Double(todaySteps) / Double(max(1, currentGoal))) }

    /// Tracking "day" starts at 3 AM local time (not midnight).
    var dayStart: Date {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day], from: Date())
        c.hour = 3; c.minute = 0; c.second = 0
        guard let t = cal.date(from: c) else { return cal.startOfDay(for: Date()) }
        return Date() < t ? t.addingTimeInterval(-86400) : t
    }

    init() { loadPersistedValues() }

    func initialize() async {
        switch trackingMode {
        case .healthKit: await authorizeAndFetchHealthKit()
        case .appOnly:   startPedometer()
        }
    }

    func switchTrackingMode(to mode: TrackingMode) {
        pedometer.stopUpdates()
        trackingMode = mode
        Task { await initialize() }
    }

    func refresh() async {
        if trackingMode == .healthKit { await fetchHealthKitSteps() }
    }

    // MARK: - Weekly Calendar

    func refreshWeeklyCalendar(sessions: [WalkSession], weekOffset: Int = 0) async {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())

        // The 7-day window: weekOffset=0 → -3…+3, weekOffset=-1 → -10…-4, etc.
        let base  = weekOffset * 7
        let range = (base - 3)...(base + 3)

        // Fetch HealthKit counts for any past portion of the window
        let hkCounts: [Date: Int]
        if trackingMode == .healthKit, range.lowerBound < 0 {
            let qStart = cal.date(byAdding: .day, value: range.lowerBound, to: today)!
            // +1 so qEnd is the start of the day AFTER the last wanted day,
            // ensuring enumerateStatistics includes yesterday's bucket (weekOffset=0).
            let qEnd   = cal.date(byAdding: .day, value: min(range.upperBound + 1, 0), to: today)
                         ?? today
            hkCounts = await fetchWeeklyStepCounts(from: qStart, to: qEnd)
        } else {
            hkCounts = [:]
        }

        var days: [CalendarDay] = []
        for offset in range {
            guard let date = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let wd = cal.component(.weekday, from: date)

            // Past days use frozen historical goal; today/future always track current settings
            let computed = (useCustomSchedule ? weekdayGoals[wd] : nil) ?? dailyGoal
            let goal: Int
            if offset < 0 {
                let key = dayKey(date)
                if let stored = historicalDayGoals[key] {
                    goal = stored
                } else {
                    historicalDayGoals[key] = computed
                    goal = computed
                }
            } else {
                goal = computed
            }

            let steps: Int?
            if offset > 0 {
                steps = nil
            } else if offset == 0 {
                steps = weekOffset == 0 ? todaySteps : nil
            } else if trackingMode == .healthKit {
                steps = hkCounts[date]
            } else {
                steps = sessions
                    .filter { cal.isDate($0.date, inSameDayAs: date) }
                    .reduce(0) { $0 + $1.estimatedSteps }
            }

            let tag       = weekdayTags[wd]
            let tagConfig = tag.flatMap { id in tagConfigs.first { $0.id == id } }
            days.append(CalendarDay(
                id: date, date: date, weekday: wd, goal: goal, steps: steps,
                tag: tag, tagEmoji: tagConfig?.emoji, tagColor: tagConfig?.color
            ))
        }
        weeklyCalendar = days
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale     = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func dayKey(_ date: Date) -> String {
        Self.dayFormatter.string(from: date)
    }

    func fetchStepCounts(from startDate: Date, to endDate: Date) async -> [Date: Int] {
        return await fetchWeeklyStepCounts(from: startDate, to: endDate)
    }

    private func fetchWeeklyStepCounts(from startDate: Date, to endDate: Date) async -> [Date: Int] {
        guard HKHealthStore.isHealthDataAvailable() else { return [:] }
        let cal       = Calendar.current
        let stepType  = HKQuantityType(.stepCount)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate)

        return await withCheckedContinuation { cont in
            let q = HKStatisticsCollectionQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: startDate,
                intervalComponents: DateComponents(day: 1)
            )
            q.initialResultsHandler = { _, results, _ in
                var counts: [Date: Int] = [:]
                results?.enumerateStatistics(from: startDate, to: endDate) { stats, _ in
                    let steps = stats.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    counts[cal.startOfDay(for: stats.startDate)] = Int(steps)
                }
                cont.resume(returning: counts)
            }
            healthStore.execute(q)
        }
    }

    // MARK: - HealthKit

    private func authorizeAndFetchHealthKit() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let stepType = HKQuantityType(.stepCount)
        // Write types: workout records, distance samples, calories.
        // These are requested here so a single system prompt covers all HealthKit access.
        let typesToShare: Set<HKSampleType> = [
            .workoutType(),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.activeEnergyBurned)
        ]
        var readTypes: Set<HKObjectType> = [stepType, HKQuantityType(.distanceWalkingRunning)]
        GaitHealthService.readTypes.forEach  { readTypes.insert($0) }
        RecoveryService.readTypes.forEach    { readTypes.insert($0) }
        do {
            try await healthStore.requestAuthorization(toShare: typesToShare, read: readTypes)
            permissionDenied = false
            await fetchHealthKitSteps()
            observeHealthKit()
        } catch {
            permissionDenied = true
        }
    }

    private func fetchHealthKitSteps() async {
        let predicate = HKQuery.predicateForSamples(withStart: dayStart, end: Date())
        async let steps = fetchTodaySum(HKQuantityType(.stepCount),              unit: .count(),  predicate: predicate)
        async let dist  = fetchTodaySum(HKQuantityType(.distanceWalkingRunning), unit: .meter(),  predicate: predicate)
        let (s, d) = await (steps, dist)
        todaySteps          = Int(s)
        todayDistanceMeters = d
    }

    private func fetchTodaySum(_ type: HKQuantityType, unit: HKUnit, predicate: NSPredicate) async -> Double {
        await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                      options: .cumulativeSum) { _, result, _ in
                cont.resume(returning: result?.sumQuantity()?.doubleValue(for: unit) ?? 0)
            }
            healthStore.execute(q)
        }
    }

    private func observeHealthKit() {
        let stepType = HKQuantityType(.stepCount)
        let q = HKObserverQuery(sampleType: stepType, predicate: nil) { [weak self] _, _, _ in
            Task { [weak self] in await self?.fetchHealthKitSteps() }
        }
        healthStore.execute(q)
    }

    // MARK: - Core Motion

    private func startPedometer() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometer.startUpdates(from: dayStart) { [weak self] data, error in
            guard let data, error == nil else { return }
            Task { @MainActor [weak self] in self?.todaySteps = data.numberOfSteps.intValue }
        }
    }

    // MARK: - Persistence

    private func loadPersistedValues() {
        let d = UserDefaults.standard
        // Load lockedWeekdays first so dailyGoal.didSet respects locks when it fires
        if let raw = d.array(forKey: UDKey.lockedWeekdays) as? [Int] {
            lockedWeekdays = Set(raw)
        }
        if let raw = d.dictionary(forKey: UDKey.weekdayTags) as? [String: String] {
            weekdayTags = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
        }
        if let data = d.data(forKey: UDKey.tagConfigs),
           let configs = try? JSONDecoder().decode([ActivityTagConfig].self, from: data) {
            tagConfigs = configs
        }
        if let raw = d.dictionary(forKey: UDKey.historicalDayGoals) as? [String: Int] {
            historicalDayGoals = raw
        }
        if d.object(forKey: UDKey.dailyGoal) != nil { dailyGoal = d.integer(forKey: UDKey.dailyGoal) }
        useCustomSchedule = d.bool(forKey: UDKey.useCustomSchedule)
        if let raw = d.dictionary(forKey: UDKey.weekdayGoals) as? [String: Int] {
            weekdayGoals = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
        }
    }

    private func saveWeekdayGoals() {
        let raw = Dictionary(uniqueKeysWithValues: weekdayGoals.map { ("\($0.key)", $0.value) })
        UserDefaults.standard.set(raw, forKey: UDKey.weekdayGoals)
    }

    private func saveLockedWeekdays() {
        UserDefaults.standard.set(Array(lockedWeekdays), forKey: UDKey.lockedWeekdays)
    }

    private func saveWeekdayTags() {
        let raw = Dictionary(uniqueKeysWithValues: weekdayTags.map { ("\($0.key)", $0.value) })
        UserDefaults.standard.set(raw, forKey: UDKey.weekdayTags)
    }

    private func saveTagConfigs() {
        if let data = try? JSONEncoder().encode(tagConfigs) {
            UserDefaults.standard.set(data, forKey: UDKey.tagConfigs)
        }
    }

    private func saveHistoricalDayGoals() {
        UserDefaults.standard.set(historicalDayGoals, forKey: UDKey.historicalDayGoals)
    }

    // MARK: - Streak Protection Notification

    /// Schedules a 4:30 PM nudge if the user is still short of their goal.
    /// Safe to call every time the app foregrounds — cancels itself if goal is met.
    func scheduleStreakNudge(currentStreak: Int) async {
        guard UserDefaults.standard.object(forKey: "notif_streakProtection") as? Bool ?? true else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["streak-protection"])

        let remaining = remainingSteps
        guard remaining > 500 else { return }

        // Don't schedule if the 4:30 PM window has already passed today
        let now = Date()
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = 16; comps.minute = 30
        guard let fireDate = Calendar.current.date(from: comps), fireDate > now else { return }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let walkMins = max(5, Int(Double(remaining) * 0.762 / 84))
        let content = UNMutableNotificationContent()
        content.title = currentStreak > 1
            ? "Keep your \(currentStreak)-day streak alive! 🔥"
            : "Don't break your streak today! 🔥"
        content.body = "You're \(remaining.formatted()) steps away — a \(walkMins)-min walk closes the gap."
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
            repeats: false
        )
        try? await center.add(UNNotificationRequest(
            identifier: "streak-protection", content: content, trigger: trigger
        ))
    }
}
