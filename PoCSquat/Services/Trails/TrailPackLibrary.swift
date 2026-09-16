import Foundation

// MARK: - TrailPackLibrary
//
// Owns every open region pack. The app ships its home region inside the
// bundle so a first launch works with no network (decision 2026-09-16);
// further regions arrive on demand and are opened here too. A pack that
// opens registers its attribution; a pack that closes withdraws it — the
// About screen never has to know which regions are loaded.
//
// Failure posture is fail open in the only sense that matters here: a pack
// that cannot be opened is recorded and skipped. No trails is a poorer
// screen, not a crash, and never a reason to block a walk.

@MainActor
@Observable
final class TrailPackLibrary {

    static let shared = TrailPackLibrary()

    /// Regions shipped inside the app bundle, as `<region>.wktpack`.
    static let bundledRegions = ["nc"]

    /// Open packs by region code.
    private(set) var sources: [String: BundledTrailSource] = [:]

    /// Why a pack did not open, by region. Surfaced in Settings so a bad
    /// download is visible rather than silently absent.
    private(set) var loadErrors: [String: String] = [:]

    private let registry: TrailAttributionRegistry

    init(registry: TrailAttributionRegistry? = nil) {
        self.registry = registry ?? .shared
    }

    // MARK: Opening and closing

    /// Opens every bundled region. Call once at launch. Opening is a read of
    /// SQLite's header and two small tables — milliseconds — so it runs
    /// synchronously; the first query is what touches the data.
    func loadBundled(from bundle: Bundle = .main) {
        for region in Self.bundledRegions {
            guard let url = bundle.url(forResource: region, withExtension: "wktpack") else {
                loadErrors[region] = "\(region).wktpack is not in the app bundle"
                continue
            }
            open(url: url, region: region)
        }
    }

    /// Opens the pack at `url` under `region`, replacing any pack already
    /// open for that region. Records rather than throws on failure.
    @discardableResult
    func open(url: URL, region: String) -> BundledTrailSource? {
        close(region: region)
        do {
            let source = try BundledTrailSource(url: url)
            sources[region] = source
            loadErrors[region] = nil
            registry.register(source, token: region)
            return source
        } catch {
            loadErrors[region] = Self.describe(error)
            return nil
        }
    }

    func close(region: String) {
        guard sources.removeValue(forKey: region) != nil else { return }
        registry.unregister(token: region)
    }

    // MARK: Reading

    func source(for region: String) -> BundledTrailSource? { sources[region] }

    /// Every open pack's metadata, in region order — for Settings.
    var packInfos: [TrailPackInfo] {
        sources.keys.sorted().compactMap { sources[$0]?.packInfo }
    }

    private static func describe(_ error: Error) -> String {
        switch error as? TrailPackError {
        case .cannotOpen(_, let detail): return "Could not open: \(detail)"
        case .unsupportedSchema(let found, let supported):
            return "Pack schema \(found) is not supported by this version (reads \(supported.lowerBound)–\(supported.upperBound))"
        case .malformed(let detail): return "Pack is malformed: \(detail)"
        case .queryFailed(let detail): return "Pack query failed: \(detail)"
        case nil: return error.localizedDescription
        }
    }
}
