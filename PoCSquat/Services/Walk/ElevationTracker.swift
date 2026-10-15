import Foundation

// MARK: - Elevation gain (feat/walk-elevation-gain)
//
// How much an outdoor walk, run or ride climbed and descended, from the
// altitude each GPS fix already carries. No barometer and no terrain service:
// the figure is made on the phone during the activity and never recomputed
// afterwards. Apps that "correct" elevation after the hike are the ones
// people complain double the gain or invent climbs on flat walks (spec,
// 2026-10-15).

/// The climb an activity is saved with, in metres. Nil on a `WalkSession`
/// means no usable altitude at all (indoor, before 1.17, or no fix good
/// enough), which is never shown as a flat 0.
struct ElevationTotals: Codable, Equatable {
    let ascentMeters: Double
    let descentMeters: Double
}

/// Accumulates ascent and descent from GPS altitude, ignoring noise.
///
/// A fix counts only when its `verticalAccuracy` is known (not negative) and
/// no worse than `maxVerticalAccuracy`. Its altitude is averaged with the
/// previous `smoothingWindow - 1` usable fixes, and that level must then move
/// more than `hysteresis` away from the last counted level before the change
/// counts, so GPS altitude drifting while standing still adds nothing.
///
/// Why the average: a 3 m hysteresis alone rejects only jitter under 3 m
/// peak to peak. Jitter of ±2.5 m is 5 m peak to peak; once the level sat at
/// one extreme, every swing to the other counted, and a flat walk could save
/// a climb of a hundred metres (critic, 2026-10-15). Averaging five fixes
/// costs a couple of metres of a climb's final stretch, which `ascent` may
/// therefore understate; it never overstates.
/// After a gap (no usable fix for `maxGap`, or a stretch the walk's distance
/// skipped) the level is re-anchored at the new fix without counting the
/// difference, so a gap never invents a climb.
struct ElevationTracker {
    static let maxVerticalAccuracy: Double = 15
    static let hysteresis: Double = 3
    static let maxGap: TimeInterval = 60
    static let smoothingWindow = 5

    private(set) var ascent: Double = 0
    private(set) var descent: Double = 0
    /// True once any usable fix arrived, so "no data" stays nil, not 0.
    private(set) var hasFix = false
    /// The last counted level. Nil until a fix arrives, and after a restore.
    private var anchor: Double?
    private var lastFixTime: Date?
    /// The last usable altitudes, oldest first, at most `smoothingWindow`.
    private var recent: [Double] = []

    init() {}

    /// Picks up a restored session's totals. The level is re-anchored at the
    /// next fix: the app was closed for an unknown time in between.
    init(restoring saved: ElevationTotals?) {
        guard let saved else { return }
        ascent = max(0, saved.ascentMeters)
        descent = max(0, saved.descentMeters)
        hasFix = true
    }

    /// Feeds one fix. `continuous` is false when the walk did not count the
    /// distance since the previous fix (a jump of 100 m or more), so the
    /// altitude change over that stretch is not counted either.
    mutating func add(altitude: Double, verticalAccuracy: Double, at time: Date, continuous: Bool = true) {
        // A skipped stretch breaks the level even when this fix's altitude is
        // unusable: the next good fix is past the jump (critic, 2026-10-15).
        if !continuous { restartLevel() }
        guard verticalAccuracy >= 0, verticalAccuracy <= Self.maxVerticalAccuracy,
              altitude.isFinite else { return }
        defer { lastFixTime = time }
        hasFix = true
        if let last = lastFixTime, time.timeIntervalSince(last) > Self.maxGap { restartLevel() }
        recent.append(altitude)
        if recent.count > Self.smoothingWindow { recent.removeFirst() }
        let smoothed = recent.reduce(0, +) / Double(recent.count)
        guard let level = anchor else {
            anchor = smoothed
            return
        }
        let change = smoothed - level
        if change > Self.hysteresis {
            ascent += change
            anchor = smoothed
        } else if change < -Self.hysteresis {
            descent -= change
            anchor = smoothed
        }
    }

    /// Forgets the level and the fixes behind it; the next usable fix starts
    /// a new level without counting the difference.
    private mutating func restartLevel() {
        anchor = nil
        recent = []
    }

    /// What the crash checkpoint and the finished activity keep.
    var totals: ElevationTotals? {
        hasFix ? ElevationTotals(ascentMeters: ascent, descentMeters: descent) : nil
    }
}
