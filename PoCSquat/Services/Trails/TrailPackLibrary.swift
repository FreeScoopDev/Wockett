import Foundation

// MARK: - TrailPackLibrary
//
// Owns every open region pack. The app ships its home region inside the
// bundle so a first launch works with no network (decision 2026-09-16);
// further regions — and the full version of the home region — download on
// demand from the CloudKit catalogue and live in Application Support. A pack
// that opens registers its attribution; a pack that closes withdraws it —
// the About screen never has to know which regions are loaded.
//
// Failure posture is fail open in the only sense that matters here: a pack
// that cannot be opened is recorded and skipped. No trails is a poorer
// screen, not a crash, and never a reason to block a walk.

@MainActor
@Observable
final class TrailPackLibrary {

    static let shared = TrailPackLibrary()

    /// Regions shipped inside the app bundle, as `<region>.wktpack`. The
    /// bundled copy is the trimmed one (named trails only); a downloaded
    /// pack for the same region replaces it while installed.
    static let bundledRegions = ["nc"]

    /// Open packs by region code.
    private(set) var sources: [String: BundledTrailSource] = [:]

    /// Why a pack did not open, by region. Surfaced in Settings so a bad
    /// download is visible rather than silently absent.
    private(set) var loadErrors: [String: String] = [:]

    // MARK: Catalogue and installs

    enum RegionState: Equatable {
        /// Only the bundled trimmed pack is loaded (home region).
        case bundled
        /// A downloaded pack is installed at this version.
        case installed(packVersion: Int)
        /// Installed, and the catalogue has a newer pack.
        case updateAvailable(installed: Int, latest: Int)
        /// In the catalogue, not on the device.
        case available
        /// In the catalogue, but this build cannot read its schema.
        case needsAppUpdate
        case downloading(progress: Double)
        case failed(String)
    }

    /// The catalogue as last fetched. Empty until `refreshCatalog()` runs;
    /// never fetched at launch — only when the user opens the regions screen.
    private(set) var catalog: [TrailRegionRecord] = []
    private(set) var catalogError: String?
    private(set) var isRefreshingCatalog = false

    /// Installed downloads: region → pack version. Persisted as a manifest
    /// next to the packs so an update can be offered by comparing versions
    /// without opening every file.
    private(set) var installed: [String: Int] = [:]
    private var transient: [String: RegionState] = [:]

    private let registry: TrailAttributionRegistry
    private let remote: TrailRegionRemote
    private let packsDirectory: URL
    private let fileManager = FileManager.default

    init(registry: TrailAttributionRegistry? = nil,
         remote: TrailRegionRemote? = nil,
         packsDirectory: URL? = nil) {
        self.registry = registry ?? .shared
        self.remote = remote ?? CloudKitTrailRegionRemote()
        self.packsDirectory = packsDirectory ?? Self.defaultPacksDirectory()
        installed = Self.readManifest(at: manifestURL)
    }

    // MARK: Opening and closing

    /// Opens every bundled region, then every installed download on top.
    /// Call once at launch. Opening is a read of SQLite's header and two
    /// small tables — milliseconds — so it runs synchronously.
    func loadBundled(from bundle: Bundle = .main) {
        for region in Self.bundledRegions {
            guard let url = bundle.url(forResource: region, withExtension: "wktpack") else {
                loadErrors[region] = "\(region).wktpack is not in the app bundle"
                continue
            }
            open(url: url, region: region)
        }
        for region in installed.keys.sorted() {
            open(url: packURL(for: region), region: region)
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

    // MARK: Catalogue

    func refreshCatalog() async {
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }
        do {
            catalog = try await remote.availableRegions().sorted { $0.regionName < $1.regionName }
            catalogError = nil
        } catch {
            catalogError = error.localizedDescription
        }
    }

    func state(of record: TrailRegionRecord) -> RegionState {
        if let t = transient[record.region] { return t }
        if let version = installed[record.region] {
            return record.packVersion > version
                ? .updateAvailable(installed: version, latest: record.packVersion)
                : .installed(packVersion: version)
        }
        if !record.isReadable { return .needsAppUpdate }
        return Self.bundledRegions.contains(record.region) ? .bundled : .available
    }

    // MARK: Download and remove

    /// Downloads and installs `record`'s pack, replacing whatever is open
    /// for the region. The new pack is opened from a temporary location
    /// first: a download that cannot be read is discarded and reported, and
    /// the previous pack (bundled or installed) stays in place.
    func download(_ record: TrailRegionRecord) async {
        guard record.isReadable else {
            transient[record.region] = .needsAppUpdate
            return
        }
        transient[record.region] = .downloading(progress: 0)
        do {
            // The weak capture goes on the inner Task, not the outer closure: a
            // `[weak self]` there is a captured *var*, and reading it from the
            // concurrently-executing Task is a Swift 6 error.
            let temp = try await remote.downloadPack(record) { fraction in
                Task { @MainActor [weak self] in self?.transient[record.region] = .downloading(progress: fraction) }
            }
            defer { try? fileManager.removeItem(at: temp) }

            // Open before install: refuse a pack this build cannot read
            // without touching what is already installed.
            _ = try BundledTrailSource(url: temp)

            try fileManager.createDirectory(at: packsDirectory, withIntermediateDirectories: true)
            let destination = packURL(for: record.region)
            close(region: record.region)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temp, to: destination)
            Self.excludeFromBackup(destination)

            installed[record.region] = record.packVersion
            writeManifest()
            open(url: destination, region: record.region)
            transient[record.region] = nil
        } catch {
            transient[record.region] = .failed(Self.describe(error))
            // Whatever was open before is still open; if we closed it above
            // and the move failed, fall back to the bundled copy.
            if sources[record.region] == nil { reopenFallback(for: record.region) }
        }
    }

    /// Removes an installed download. The bundled pack, if the region has
    /// one, is reopened so the home region never goes dark.
    func remove(region: String) {
        close(region: region)
        try? fileManager.removeItem(at: packURL(for: region))
        installed[region] = nil
        transient[region] = nil
        writeManifest()
        reopenFallback(for: region)
    }

    private func reopenFallback(for region: String, bundle: Bundle = .main) {
        guard Self.bundledRegions.contains(region),
              let url = bundle.url(forResource: region, withExtension: "wktpack") else { return }
        open(url: url, region: region)
    }

    // MARK: Files

    private var manifestURL: URL { packsDirectory.appendingPathComponent("installed.json") }

    func packURL(for region: String) -> URL {
        packsDirectory.appendingPathComponent("\(region).wktpack")
    }

    private static func defaultPacksDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TrailPacks", isDirectory: true)
    }

    private static func readManifest(at url: URL) -> [String: Int] {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return manifest
    }

    private func writeManifest() {
        try? fileManager.createDirectory(at: packsDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(installed) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    /// Packs are re-downloadable, so they must not count against the user's
    /// iCloud backup — Apple's data-storage guideline says so in as many words.
    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
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
