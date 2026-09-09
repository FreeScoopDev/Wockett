import CoreMotion
import Foundation

// MARK: - UntrackedWalkDetector
//
// Notices, after the fact, that the user did a walk without tracking it, and
// offers to start one. It runs inside the background-refresh task, so it CANNOT
// be timely: iOS decides when to wake the app, typically a few times a day.
// Real-time detection would need continuous background location outside a
// session — "Always" permission, constant battery drain, the blue pill — which
// was considered and rejected (2026-09-09). The copy is written for a delay:
// "You walked about 1.8 km this morning without tracking", not "you're walking".
//
// The decision is a pure function over a summarised window so it can be tested;
// the Core Motion querying around it is thin I/O.

// MARK: Sample

/// One Core Motion reading, reduced to what the policy needs. `CMMotionActivity`
/// has no public initialiser, so summarising takes this instead and the mapping
/// from Core Motion is the only untested part.
struct MotionSample: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case walking, running, cycling, other }

    let start: Date
    let kind: Kind
    let isHighConfidence: Bool

    init(start: Date, kind: Kind, isHighConfidence: Bool) {
        self.start = start
        self.kind = kind
        self.isHighConfidence = isHighConfidence
    }

    init(_ activity: CMMotionActivity) {
        start = activity.startDate
        if activity.walking        { kind = .walking }
        else if activity.running   { kind = .running }
        else if activity.cycling   { kind = .cycling }
        else                       { kind = .other }
        isHighConfidence = activity.confidence == .high
    }
}

// MARK: Window

/// What the user actually did over the queried period.
struct ActivityWindow: Equatable, Sendable {
    var activeSeconds: TimeInterval = 0
    var distanceMeters: Double = 0
    var dominant: MotionSample.Kind = .other
}

// MARK: Policy

enum UntrackedWalkPolicy {
    /// Ten minutes of movement. Shorter bursts are walking to the kitchen.
    static let minimumActiveSeconds: TimeInterval = 600
    /// …and far enough to be a walk. `walking` fires while pacing a shop, which
    /// is why duration alone is not enough.
    static let minimumDistanceMeters: Double = 500
    /// At most one of these a day, whatever the user got up to.
    static let minimumSpacing: TimeInterval = 20 * 3600

    /// Core Motion reports a *change* of activity, so a sample lasts until the
    /// next one starts (or until the end of the window for the last sample).
    /// Only high-confidence walking, running and cycling count toward the total.
    static func summarize(_ samples: [MotionSample], endingAt end: Date) -> ActivityWindow {
        let ordered = samples.sorted { $0.start < $1.start }
        var totals: [MotionSample.Kind: TimeInterval] = [:]

        for (index, sample) in ordered.enumerated() {
            let next = index + 1 < ordered.count ? ordered[index + 1].start : end
            let duration = next.timeIntervalSince(sample.start)
            guard duration > 0, sample.isHighConfidence else { continue }
            switch sample.kind {
            case .walking, .running, .cycling: totals[sample.kind, default: 0] += duration
            case .other: continue
            }
        }

        var window = ActivityWindow()
        window.activeSeconds = totals.values.reduce(0, +)
        // Ties are broken by kind order so the summary is deterministic.
        window.dominant = totals.max { lhs, rhs in
            lhs.value == rhs.value ? String(describing: lhs.key) > String(describing: rhs.key) : lhs.value < rhs.value
        }?.key ?? .other
        return window
    }

    /// Everything that has to be true before interrupting someone about a walk
    /// they have already finished.
    static func shouldNotify(window: ActivityWindow,
                             isSessionActive: Bool,
                             lastNotified: Date?,
                             now: Date) -> Bool {
        guard !isSessionActive else { return false }
        guard window.activeSeconds >= minimumActiveSeconds else { return false }
        guard window.distanceMeters >= minimumDistanceMeters else { return false }
        if let lastNotified, now.timeIntervalSince(lastNotified) < minimumSpacing { return false }
        return true
    }

    // MARK: Copy

    static func title(for window: ActivityWindow) -> String {
        switch window.dominant {
        case .running: return "You went for a run"
        case .cycling: return "You went for a ride"
        default:       return "You went for a walk"
        }
    }

    /// "About 1.8 km this morning — want to track the next one?" The distance is
    /// deliberately approximate: this came from the pedometer, not a GPS track.
    static func body(for window: ActivityWindow,
                     now: Date,
                     locale: Locale = .current,
                     calendar: Calendar = .current) -> String {
        let usesMetric = locale.measurementSystem != .us
        let measurement = Measurement(value: window.distanceMeters, unit: UnitLength.meters)
        let converted = usesMetric ? measurement.converted(to: .kilometers) : measurement.converted(to: .miles)
        let distance = String(format: "%.1f %@", converted.value, usesMetric ? "km" : "mi")

        let hour = calendar.component(.hour, from: now)
        let partOfDay: String
        switch hour {
        case 0..<12:  partOfDay = "this morning"
        case 12..<17: partOfDay = "this afternoon"
        default:      partOfDay = "this evening"
        }
        return "About \(distance) \(partOfDay), untracked. Want to track the next one?"
    }
}

// MARK: - Detector

/// Queries Core Motion for what happened since the last check and, if it looks
/// like a real walk, posts the nudge. Called from the background-refresh task.
@MainActor
final class UntrackedWalkDetector {
    static let shared = UntrackedWalkDetector()

    static let lastCheckKey    = "untrackedWalk_lastCheck"
    static let lastNotifiedKey = "untrackedWalk_lastNotified"
    /// Never look further back than this, however long the app went unopened —
    /// a nudge about Tuesday is noise on Thursday.
    static let maximumLookback: TimeInterval = 6 * 3600

    private let activityManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func check(now: Date = Date()) async {
        guard CMMotionActivityManager.isActivityAvailable(), CMPedometer.isDistanceAvailable() else { return }
        let notifications = NotificationService.shared
        guard notifications.isEnabled(.untrackedWalk) else { return }

        let last = defaults.object(forKey: Self.lastCheckKey) as? Date
        let start = max(last ?? now.addingTimeInterval(-Self.maximumLookback),
                        now.addingTimeInterval(-Self.maximumLookback))
        defaults.set(now, forKey: Self.lastCheckKey)
        guard start < now else { return }

        let samples = await queryActivity(from: start, to: now)
        var window = UntrackedWalkPolicy.summarize(samples, endingAt: now)
        guard window.activeSeconds >= UntrackedWalkPolicy.minimumActiveSeconds else { return }
        window.distanceMeters = await queryDistance(from: start, to: now)

        guard UntrackedWalkPolicy.shouldNotify(window: window,
                                               isSessionActive: ActiveWalkStore.shared.isActive,
                                               lastNotified: defaults.object(forKey: Self.lastNotifiedKey) as? Date,
                                               now: now) else { return }

        let scheduled = await notifications.schedule(.untrackedWalk,
                                                     title: UntrackedWalkPolicy.title(for: window),
                                                     body: UntrackedWalkPolicy.body(for: window, now: now),
                                                     trigger: nil)
        if scheduled { defaults.set(now, forKey: Self.lastNotifiedKey) }
    }

    // MARK: Core Motion I/O

    private func queryActivity(from start: Date, to end: Date) async -> [MotionSample] {
        await withCheckedContinuation { continuation in
            activityManager.queryActivityStarting(from: start, to: end, to: .main) { activities, _ in
                continuation.resume(returning: (activities ?? []).map(MotionSample.init))
            }
        }
    }

    private func queryDistance(from start: Date, to end: Date) async -> Double {
        await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: end) { data, _ in
                continuation.resume(returning: data?.distance?.doubleValue ?? 0)
            }
        }
    }
}
