import Foundation

// MARK: - Run pacing
//
// Current pace and automatic splits for an outdoor walk, run or ride
// (`feat/run-pace-splits`, 2026-10-14). Until then the one "pace" a session
// showed was its average since the start, the voice cue called that average
// "current pace", and a free run had no splits at all.
//
// Both types are plain values fed numbers by `NavigationSessionManager` from
// each accepted GPS fix: moving time (the session's `elapsedTime`, which
// already leaves pauses out) and distance covered. Nothing here reads
// CoreLocation or a clock, so tests drive them directly.

/// A smoothed "current pace": moving time over distance across the most
/// recent stretch of the session, rather than one fix to the next, which is
/// the figure runners complain jumps about with GPS noise.
struct RollingPace {
    /// How much recent moving time the pace covers. A starting value to tune
    /// on a real run, not a researched number.
    static let window: TimeInterval = 45
    /// Below either of these the window says too little to show a pace.
    static let minDuration: TimeInterval = 20
    static let minDistance: Double = 30
    /// No accepted fix for this long means standing still: no current pace.
    static let standingAfter: TimeInterval = 15

    private struct Sample { let elapsed: TimeInterval; let distance: Double }
    private var samples: [Sample] = []

    /// Records the session's moving time and distance at an accepted fix.
    mutating func add(elapsed: TimeInterval, distance: Double) {
        samples.append(Sample(elapsed: elapsed, distance: distance))
        // Keep the newest sample at or before the window's start (the anchor
        // the next reading interpolates from) and everything after it.
        let start = elapsed - Self.window
        if let anchor = samples.lastIndex(where: { $0.elapsed <= start }), anchor > 0 {
            samples.removeFirst(anchor)
        }
    }

    mutating func reset() { samples = [] }

    /// Seconds per kilometre over the last `window` of moving time, as of
    /// moving time `now`; nil when there is too little to go on or the
    /// person has stopped.
    func secsPerKm(at now: TimeInterval) -> Double? {
        guard let first = samples.first, let last = samples.last,
              now - last.elapsed <= Self.standingAfter else { return nil }
        let start = now - Self.window
        // Distance covered at the window's start, interpolated between the
        // fixes either side of it; before the first fix, the first fix.
        let from: Sample
        if first.elapsed >= start {
            from = first
        } else if let after = samples.firstIndex(where: { $0.elapsed > start }) {
            let a = samples[after - 1], b = samples[after]
            let t = (start - a.elapsed) / (b.elapsed - a.elapsed)
            from = Sample(elapsed: start, distance: a.distance + t * (b.distance - a.distance))
        } else {
            from = last
        }
        let duration = now - from.elapsed
        let distance = last.distance - from.distance
        guard duration >= Self.minDuration, distance >= Self.minDistance else { return nil }
        return duration / (distance / 1000)
    }
}

/// One split: where it ended, as cumulative distance and moving time since
/// the session began.
struct UnitSplit: Codable, Equatable {
    let distance: Double
    let elapsed: TimeInterval
}

/// An activity's splits, saved with it: every whole mile (US) or kilometre
/// crossed, and a final part-unit when the activity ended past the last one.
struct UnitSplits: Codable, Equatable {
    /// 1609.344 or 1000, fixed when the session started.
    let unitMeters: Double
    let splits: [UnitSplit]

    var usesMiles: Bool { unitMeters != 1000 }
}

/// Records a split each time the session crosses a whole mile or kilometre.
struct SplitTracker {
    /// The smallest final part-unit kept, as a fraction of a unit.
    static let minFinalFraction = 0.1

    let unitMeters: Double
    private(set) var splits: [UnitSplit]
    private var lastElapsed: TimeInterval
    private var lastDistance: Double
    /// False when units were crossed that this tracker never saw: a session
    /// restored from a checkpoint without splits (before 1.17) past its first
    /// unit. Such a session records no splits at all rather than wrong ones.
    private(set) var isTracking: Bool

    init(unitMeters: Double) {
        self.unitMeters = unitMeters
        splits = []
        lastElapsed = 0
        lastDistance = 0
        isTracking = true
    }

    /// Picks up a restored session: its whole splits so far, and where it is
    /// now, so no unit is recorded or announced twice. Pass the checkpoint's
    /// splits, or nil for a checkpoint written before splits existed.
    init(restoring saved: UnitSplits?, unitMeters fallbackUnit: Double,
         elapsed: TimeInterval, distance: Double) {
        // A unit of 0 could only come from a corrupt checkpoint; it would
        // make every distance infinitely many units.
        unitMeters = (saved?.unitMeters).flatMap { $0 > 0 ? $0 : nil } ?? fallbackUnit
        // A checkpoint holds whole units only; anything past the distance
        // now (which a restore never moves backwards) is left out regardless.
        splits = (saved?.splits ?? []).filter { $0.distance <= distance }
        lastElapsed = elapsed
        lastDistance = distance
        isTracking = splits.count >= Int(distance / unitMeters)
    }

    /// The splits so far, as the crash checkpoint keeps them.
    var state: UnitSplits { UnitSplits(unitMeters: unitMeters, splits: splits) }

    /// Moves to the session's moving time and distance at a new fix, and
    /// returns the splits completed since the last one (usually none, at
    /// most one unless a fix jumped). Each crossing's time is interpolated
    /// between the two fixes either side of it.
    mutating func add(elapsed: TimeInterval, distance: Double) -> [UnitSplit] {
        var completed: [UnitSplit] = []
        while isTracking, distance >= Double(splits.count + 1) * unitMeters, distance > lastDistance {
            let target = Double(splits.count + 1) * unitMeters
            let t = (target - lastDistance) / (distance - lastDistance)
            let split = UnitSplit(distance: target, elapsed: lastElapsed + t * (elapsed - lastElapsed))
            splits.append(split)
            completed.append(split)
        }
        lastElapsed = elapsed
        lastDistance = distance
        return completed
    }

    /// The splits an activity is saved with: the whole ones, and a final
    /// part-unit when at least `minFinalFraction` of a unit was covered past
    /// the last. Nil when there are none.
    func finished(elapsed: TimeInterval, distance: Double) -> UnitSplits? {
        guard isTracking else { return nil }
        var all = splits
        let done = Double(splits.count) * unitMeters
        if distance - done >= Self.minFinalFraction * unitMeters {
            all.append(UnitSplit(distance: distance, elapsed: elapsed))
        }
        return all.isEmpty ? nil : UnitSplits(unitMeters: unitMeters, splits: all)
    }
}
