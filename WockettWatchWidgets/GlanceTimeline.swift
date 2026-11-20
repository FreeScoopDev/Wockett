import SwiftUI
import WidgetKit

// The watch complications' timeline (feat/watch-complications). The Watch
// app stores the phone's newest glance in the watch's App Group
// (`WatchGlanceStorage`) and reloads these timelines; this extension only
// reads it. What each family shows at a given moment (stale day, no data,
// no pets) is decided by `WatchGlanceDisplay` in the shared
// WatchGlance.swift, which the app's unit tests cover.

struct GlanceEntry: TimelineEntry {
    let date: Date
    /// Nil until the phone has sent one: the views show a placeholder.
    let snapshot: WatchGlanceSnapshot?

    var steps: WatchGlanceDisplay.StepsGlance { WatchGlanceDisplay.steps(snapshot, now: date) }
    var pets: WatchGlanceDisplay.PetsGlance { WatchGlanceDisplay.pets(snapshot, now: date) }
}

struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: Date(), snapshot: .sample(now: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        let now = Date()
        let stored = WatchGlanceStorage.load(from: AppGroup.defaults)
        // The gallery shows sample numbers until the phone has sent real ones.
        completion(GlanceEntry(date: now, snapshot: context.isPreview && stored == nil ? .sample(now: now) : stored))
    }

    /// One entry now and one at each day end still ahead (the phone's 3 AM
    /// step day and the pets' midnight), so the day rolls over without a
    /// push. The Watch app reloads the timeline when new numbers arrive.
    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let now = Date()
        let stored = WatchGlanceStorage.load(from: AppGroup.defaults)
        let entries = WatchGlanceDisplay.entryDates(stored, now: now).map { GlanceEntry(date: $0, snapshot: stored) }
        completion(Timeline(entries: entries, policy: .never))
    }
}

extension WatchGlanceSnapshot {
    /// Clearly made-up numbers for placeholders, the gallery and previews.
    static func sample(now: Date, steps: Int? = 6_240, pets: Bool = true) -> WatchGlanceSnapshot {
        let samplePets = pets ? [
            WatchGlancePet(id: UUID(), name: "Sample dog", emoji: "🐕", steps: 4_100, goal: 8_000),
            WatchGlancePet(id: UUID(), name: "Sample cat", emoji: "🐈", steps: 1_250, goal: 5_000)
        ] : []
        return .make(steps: steps, goal: 10_000, pets: samplePets, dayStart: Calendar.current.startOfDay(for: now), now: now)
    }
}

/// The gauge colour: the brand green in full colour; in the tinted and
/// accented faces the system recolours it, and `widgetAccentable` puts it in
/// the accent group so it stays the part that stands out.
struct GlanceTint {
    let mode: WidgetRenderingMode

    var steps: Color { mode == .fullColor ? .earthGreen : .primary }
    var pets: Color { mode == .fullColor ? .earthOrange : .primary }
    var secondaryText: Color { mode == .fullColor ? .earthMuted : .secondary }
}
