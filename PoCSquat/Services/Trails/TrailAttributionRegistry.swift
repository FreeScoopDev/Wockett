import Foundation

// MARK: - TrailAttributionRegistry
//
// The one place that knows which data sources are live and what they require
// to be said about them. The About screen renders whatever is registered;
// no attribution string is ever typed into a view by hand. That is the same
// copy-paste-drift problem the design tokens solved — and here it is also a
// licence obligation (ODbL for OpenStreetMap), so drift is not cosmetic.
//
// Sources register when they are opened and unregister when they are dropped,
// so a region the user deletes stops being credited, and one they download
// starts being credited, without any view changing.

@Observable
final class TrailAttributionRegistry {

    static let shared = TrailAttributionRegistry()

    /// Attributions currently in effect, one per source, in first-registered
    /// order. Two packs from the same source (two OSM regions) credit it once.
    private(set) var attributions: [TrailAttribution] = []

    /// Which registrants contribute each source, so a source stays credited
    /// while any pack that uses it is still open.
    private var holders: [String: Set<String>] = [:]

    init() {}

    /// Registers `source`'s attributions under `token` — normally the pack's
    /// region id.
    func register(_ source: TrailDataSource, token: String) {
        for attribution in source.attributions {
            holders[attribution.sourceID, default: []].insert(token)
            if !attributions.contains(where: { $0.sourceID == attribution.sourceID }) {
                attributions.append(attribution)
            }
        }
    }

    /// Drops `token`'s claim on every source; a source with no remaining
    /// holders leaves the list.
    func unregister(token: String) {
        for (sourceID, tokens) in holders {
            var remaining = tokens
            remaining.remove(token)
            if remaining.isEmpty {
                holders[sourceID] = nil
                attributions.removeAll { $0.sourceID == sourceID }
            } else {
                holders[sourceID] = remaining
            }
        }
    }

    /// Only the credits the licence actually demands, for a compact footer.
    var required: [TrailAttribution] { attributions.filter(\.requiresAttribution) }
}
