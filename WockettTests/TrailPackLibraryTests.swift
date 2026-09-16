import Testing
import CoreLocation
import Foundation
@testable import PoCSquat

/// `TrailPackLibrary` owns open packs and keeps the attribution registry in
/// step with them. The last test opens the pack the app actually ships —
/// `Bundle.main` is the host app under unit tests — so a broken or missing
/// bundled pack fails here, not on a user's first launch.
@MainActor
struct TrailPackLibraryTests {

    private final class Marker {}

    private var fixtureURL: URL {
        get throws {
            let bundle = Bundle(for: Marker.self)
            return try #require(bundle.url(forResource: "fixture", withExtension: "wktpack"))
        }
    }

    @Test("Opening a pack registers its attribution; closing withdraws it")
    func openAndClose() throws {
        let registry = TrailAttributionRegistry()
        let library = TrailPackLibrary(registry: registry)
        let src = library.open(url: try fixtureURL, region: "fixture")
        #expect(src != nil)
        #expect(library.source(for: "fixture") === src)
        #expect(registry.attributions.map(\.sourceID) == ["osm"])
        #expect(library.packInfos.map(\.region) == ["fixture"])
        #expect(library.loadErrors.isEmpty)

        library.close(region: "fixture")
        #expect(library.source(for: "fixture") == nil)
        #expect(registry.attributions.isEmpty)
        #expect(library.packInfos.isEmpty)
    }

    @Test("Re-opening a region replaces the pack without double-crediting")
    func reopenReplaces() throws {
        let registry = TrailAttributionRegistry()
        let library = TrailPackLibrary(registry: registry)
        library.open(url: try fixtureURL, region: "fixture")
        library.open(url: try fixtureURL, region: "fixture")
        #expect(library.sources.count == 1)
        #expect(registry.attributions.count == 1)
        library.close(region: "fixture")
        #expect(registry.attributions.isEmpty, "one close is enough — the first open was withdrawn by the second")
    }

    @Test("A pack that cannot be opened is recorded, not thrown, and credits nothing")
    func badPackIsRecorded() {
        let registry = TrailAttributionRegistry()
        let library = TrailPackLibrary(registry: registry)
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).wktpack")
        #expect(library.open(url: missing, region: "x") == nil)
        #expect(library.loadErrors["x"]?.hasPrefix("Could not open") == true)
        #expect(library.source(for: "x") == nil)
        #expect(registry.attributions.isEmpty)
    }

    @Test("A bundle without the region records a clear error")
    func bundleWithoutRegion() {
        let registry = TrailAttributionRegistry()
        let library = TrailPackLibrary(registry: registry)
        // The test bundle has fixture.wktpack, not nc.wktpack.
        library.loadBundled(from: Bundle(for: Marker.self))
        #expect(library.loadErrors["nc"] == "nc.wktpack is not in the app bundle")
        #expect(library.sources.isEmpty)
    }

    @Test("The pack the app ships opens, is the supported schema, and credits OpenStreetMap")
    func shippedPackOpens() throws {
        let registry = TrailAttributionRegistry()
        let library = TrailPackLibrary(registry: registry)
        library.loadBundled(from: .main)
        #expect(library.loadErrors.isEmpty, "\(library.loadErrors)")
        let nc = try #require(library.source(for: "nc"))
        #expect(nc.packInfo.region == "nc")
        #expect(nc.packInfo.regionName == "North Carolina")
        #expect(BundledTrailSource.supportedSchemaVersions.contains(nc.packInfo.schemaVersion))
        #expect(nc.packInfo.trailCount > 9_000, "named-only NC pack was 9,328 trails when bundled")
        #expect(nc.packInfo.builtAt != nil)
        #expect(registry.required.map(\.sourceID) == ["osm"])

        // And it answers. Downtown Raleigh, 5 km.
        let near = try nc.trails(near: CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64), radiusMeters: 5_000,
                                 matching: .any, limit: 10)
        #expect(!near.isEmpty)
        #expect(near.allSatisfy { $0.name != nil }, "the bundled pack is named trails only")
    }
}
