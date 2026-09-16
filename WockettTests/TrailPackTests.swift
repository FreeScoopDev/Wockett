import Testing
import CoreLocation
import Foundation
import SQLite3
@testable import PoCSquat

/// Reads `Fixtures/fixture.wktpack`, a six-trail pack built by the real
/// `tools/build_trail_pack.py` from `scripts/trail-fixture/trails-fixture.geojsonseq`
/// (see `scripts/trail-fixture/build_fixture.sh`). Building it with the real tool is the
/// point: on 2026-09-10 a hand-made fixture agreed with the code instead of
/// with the tool and hid two bugs.
///
/// Fixture contents, from the builder's `--inspect`:
///   1 Lake Loop Trail     1001 m  gravel   leashRequired/tagged     loop
///   2 Riverside Greenway  2997 m  asphalt  leashRequired/tagged     bike
///   3 Dog Park Path        220 m  ground   offLeashAllowed/tagged
///   4 (unnamed)            899 m  dirt     notPermitted/inferred
///   5 Far Ridge Trail     7990 m  ground   notPermitted/tagged      horse, ~20 km north
///   6 (unnamed)            120 m  —        unknown/default
@MainActor
struct TrailPackTests {

    private final class Marker {}

    private var fixtureURL: URL {
        get throws {
            let bundle = Bundle(for: Marker.self)
            guard let url = bundle.url(forResource: "fixture", withExtension: "wktpack") else {
                throw TrailPackError.cannotOpen(path: "fixture.wktpack", detail: "not in test bundle — is WockettTests/Fixtures a synchronized folder?")
            }
            return url
        }
    }

    private func open() throws -> BundledTrailSource { try BundledTrailSource(url: try fixtureURL) }

    /// A writable copy of the fixture in the temp directory, for tests that
    /// need to change what the pack says. The bundle resource is never touched.
    private func scratchCopy() throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wktpack")
        try FileManager.default.copyItem(at: try fixtureURL, to: copy)
        return copy
    }

    /// Downtown Raleigh, inside the Lake Loop.
    private let raleigh = CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64)

    // MARK: Opening

    @Test("Opens the fixture and reads its metadata")
    func opensAndReadsMeta() throws {
        let src = try open()
        #expect(src.packInfo.schemaVersion == 1)
        #expect(src.packInfo.region == "fixture")
        #expect(src.packInfo.regionName == "Test Fixture")
        #expect(src.packInfo.trailCount == 6)
        #expect(src.packInfo.sourceIDs == ["osm"])
        #expect(src.packInfo.builtAt != nil)
    }

    @Test("Attribution travels with the pack")
    func attribution() throws {
        let src = try open()
        #expect(src.attributions.count == 1)
        let osm = try #require(src.attributions.first)
        #expect(osm.sourceID == "osm")
        #expect(osm.attribution.contains("OpenStreetMap"))
        #expect(osm.license.contains("ODbL"))
        #expect(osm.requiresAttribution)
    }

    @Test("A missing file is a cannotOpen error, not a trap")
    func missingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).wktpack")
        #expect { try BundledTrailSource(url: url) } throws: { error in
            if case .cannotOpen = error as? TrailPackError { return true }
            return false
        }
    }

    @Test("A pack with an unsupported schema version is refused")
    func unsupportedSchema() throws {
        // Copy the fixture and bump its schema_version past what this build reads.
        let copy = try scratchCopy()
        defer { try? FileManager.default.removeItem(at: copy) }
        var db: OpaquePointer?
        #expect(sqlite3_open(copy.path, &db) == SQLITE_OK)
        let future = BundledTrailSource.supportedSchemaVersions.upperBound + 1
        #expect(sqlite3_exec(db, "UPDATE meta SET value = '\(future)' WHERE key = 'schema_version'", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        #expect(throws: TrailPackError.unsupportedSchema(found: future, supported: BundledTrailSource.supportedSchemaVersions)) {
            try BundledTrailSource(url: copy)
        }
    }

    // MARK: Rows

    @Test("Maps every column of a row, including the dog-access vocabulary")
    func mapsRow() throws {
        let src = try open()
        let loop = try #require(try src.trail(id: 1))
        #expect(loop.name == "Lake Loop Trail")
        #expect(loop.sourceID == "osm")
        #expect(loop.sourceRef == "w1")
        #expect(abs(loop.lengthMeters - 1001) < 2)
        #expect(loop.surface == "gravel")
        #expect(loop.difficulty == "hiking")
        #expect(loop.dogAccess == .leashRequired)
        #expect(loop.dogAccessProvenance == .tagged)
        #expect(loop.dogAccessIsConfident)
        #expect(loop.isLoop)
        #expect(loop.allowsFoot)
        #expect(!loop.allowsBike)
        #expect(loop.pointCount == 25)
        #expect(loop.coordinates.count == 25)

        let ridge = try #require(try src.trail(id: 5))
        #expect(ridge.allowsHorse)
        #expect(ridge.dogAccess == .notPermitted)
        #expect(ridge.difficulty == "mountain_hiking")

        let track = try #require(try src.trail(id: 4))
        #expect(track.name == nil)
        #expect(track.displayName == "Unnamed Trail")
        #expect(track.dogAccess == .notPermitted)
        #expect(track.dogAccessProvenance == .inferred)
        #expect(!track.dogAccessIsConfident)

        let spur = try #require(try src.trail(id: 6))
        #expect(spur.surface == nil)
        #expect(spur.difficulty == nil)
        #expect(spur.dogAccess == .unknown)
        #expect(spur.dogAccessProvenance == .default)

        #expect(try src.trail(id: 999) == nil)
    }

    // MARK: Near-me

    @Test("Trails near a point come back nearest first and exclude the far one")
    func nearMe() throws {
        let src = try open()
        let near = try src.trails(near: raleigh, radiusMeters: 2_000, matching: .any, limit: 50)
        // Nearest vertex to the centre, by haversine: 6 at ~143 m, 1 (loop)
        // at 160 m, 3 at ~212 m, 2 at ~716 m. 4 starts ~2.1 km away and 5 is
        // ~20 km north, so neither is inside a 2 km radius.
        #expect(near.map(\.id) == [6, 1, 3, 2])
    }

    @Test("Radius is a real distance, not a bounding-box hit")
    func radiusIsDistance() throws {
        let src = try open()
        // 50 m from the loop's centre: the loop is a 160 m circle, so its
        // bounding box contains the point but no vertex is within 50 m.
        let tight = try src.trails(near: raleigh, radiusMeters: 50, matching: .any, limit: 50)
        #expect(tight.isEmpty)
        let loose = try src.trails(near: raleigh, radiusMeters: 200, matching: .any, limit: 50)
        #expect(loose.map(\.id).contains(1))
    }

    @Test("Standing on the middle of a straight trail counts as being on it")
    func midpointOfStraightTrail() throws {
        // Trail 2 (Riverside Greenway) is 3 km long and, after simplification,
        // exactly two vertices. Its midpoint is ~1.5 km from either one, so a
        // nearest-vertex distance would say a user standing on it is 1.5 km
        // away and a 300 m radius would exclude it.
        let src = try open()
        let greenway = try #require(try src.trail(id: 2))
        #expect(greenway.pointCount == 2, "precondition: the builder simplified it to one segment")
        let midpoint = CLLocationCoordinate2D(latitude: 35.79766, longitude: -78.63932)
        let hits = try src.trails(near: midpoint, radiusMeters: 300, matching: .any, limit: 50)
        #expect(hits.map(\.id) == [2])
        #expect(BundledTrailSource.distanceMeters(from: midpoint, to: greenway) < 5)
    }

    @Test("The nearest trail is found even when hundreds share the search box")
    func nearestSurvivesADenseBox() throws {
        // Downtown Raleigh has 287 trails inside a 2 km box. A capped index scan
        // returns an arbitrary subset in R*Tree order, and ranking that subset
        // silently drops the closest trails. Reproduce the shape: 300 identical
        // trails 1.5 km away, then one 20 m away inserted last.
        let copy = try scratchCopy()
        defer { try? FileManager.default.removeItem(at: copy) }
        var db: OpaquePointer?
        #expect(sqlite3_open(copy.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func insert(id: Int, name: String, polyline: String, lat: Double) {
            let sql = """
                INSERT INTO trails (id, source_id, source_ref, name, polyline, point_count, length_m,
                    min_lat, min_lon, max_lat, max_lon, surface, difficulty, dog_access, dog_access_provenance,
                    allows_foot, allows_bike, allows_horse, is_loop, tags_json)
                VALUES (\(id), 'osm', 'w\(id)', '\(name)', '\(polyline)', 2, 90,
                    \(lat), -78.64, \(lat), -78.639, NULL, NULL, 'unknown', 'default', 1, 0, 0, 0, '{}');
                INSERT INTO trails_rtree (id, min_lat, max_lat, min_lon, max_lon)
                VALUES (\(id), \(lat), \(lat), -78.64, -78.639);
                """
            let rc = sqlite3_exec(db, sql, nil, nil, nil)
            #expect(rc == SQLITE_OK, Comment(rawValue: String(cString: sqlite3_errmsg(db))))
        }
        for id in 100..<400 { insert(id: id, name: "Far \(id)", polyline: "g|myE~j~~M?gE", lat: 35.79348) }
        insert(id: 400, name: "Near", polyline: "cikyE~j~~M?gE", lat: 35.78018)

        let src = try BundledTrailSource(url: copy)
        let top = try src.trails(near: raleigh, radiusMeters: 2_000, matching: .any, limit: 5)
        #expect(top.first?.id == 400, "the 20 m trail must rank first")
        #expect(top.count == 5)

        // R*Tree traversal order is not insertion order, so whether a capped
        // scan happens to include the near trail is luck — the assertion above
        // is a smoke check, not a guard. The count is a guard against any fixed
        // scan cap: every trail inside the radius must be considered — 300
        // synthetic, the near one, and fixture trails 1, 2, 3 and 6. (A cap
        // proportional to `limit` would slip past it; the code has none.)
        let all = try src.trails(near: raleigh, radiusMeters: 2_000, matching: .any, limit: 1_000)
        #expect(all.count == 305)
    }

    @Test("Limit is honoured")
    func limit() throws {
        let src = try open()
        let two = try src.trails(near: raleigh, radiusMeters: 50_000, matching: .any, limit: 2)
        #expect(two.count == 2)
    }

    // MARK: Filters

    @Test("Dog-access filter")
    func dogFilter() throws {
        let src = try open()
        let ok = try src.trails(near: raleigh, radiusMeters: 50_000,
                                matching: TrailQuery(dogAccess: [.offLeashAllowed, .leashRequired]), limit: 50)
        #expect(Set(ok.map(\.id)) == [1, 2, 3])
    }

    @Test("Length filters")
    func lengthFilters() throws {
        let src = try open()
        let short = try src.trails(near: raleigh, radiusMeters: 50_000,
                                   matching: TrailQuery(maxLengthMeters: 500), limit: 50)
        #expect(Set(short.map(\.id)) == [3, 6])
        let mid = try src.trails(near: raleigh, radiusMeters: 50_000,
                                 matching: TrailQuery(minLengthMeters: 800, maxLengthMeters: 3_000), limit: 50)
        #expect(Set(mid.map(\.id)) == [1, 2, 4])
    }

    @Test("Surface, bike and loop filters")
    func surfaceBikeLoop() throws {
        let src = try open()
        let ground = try src.trails(near: raleigh, radiusMeters: 50_000,
                                    matching: TrailQuery(surfaces: ["ground"]), limit: 50)
        #expect(Set(ground.map(\.id)) == [3, 5])
        let bike = try src.trails(near: raleigh, radiusMeters: 50_000,
                                  matching: TrailQuery(allowsBike: true), limit: 50)
        #expect(bike.map(\.id) == [2])
        let loops = try src.trails(near: raleigh, radiusMeters: 50_000,
                                   matching: TrailQuery(loopsOnly: true), limit: 50)
        #expect(loops.map(\.id) == [1])
    }

    @Test("Name search is a bound LIKE, and wildcards in the needle are literal")
    func nameSearch() throws {
        let src = try open()
        let river = try src.trails(near: raleigh, radiusMeters: 50_000,
                                   matching: TrailQuery(nameContains: "river"), limit: 50)
        #expect(river.map(\.id) == [2])
        // A bare "%" would match every named row if it were interpolated.
        let percent = try src.trails(near: raleigh, radiusMeters: 50_000,
                                     matching: TrailQuery(nameContains: "%"), limit: 50)
        #expect(percent.isEmpty)
    }

    @Test("Viewport query returns what intersects the box")
    func viewport() throws {
        let src = try open()
        // A box around the far ridge only.
        let box = TrailBounds(minLatitude: 35.95, minLongitude: -78.7, maxLatitude: 36.1, maxLongitude: -78.5)
        let hits = try src.trails(in: box, matching: .any, limit: 50)
        #expect(hits.map(\.id) == [5])
    }

    // MARK: Attribution registry

    @Test("Registry credits a source once across packs and drops it when the last holder leaves")
    func registry() throws {
        let registry = TrailAttributionRegistry()
        let a = try open()
        let b = try open()
        registry.register(a, token: "nc")
        registry.register(b, token: "va")
        #expect(registry.attributions.map(\.sourceID) == ["osm"])
        registry.unregister(token: "nc")
        #expect(registry.attributions.map(\.sourceID) == ["osm"], "still held by va")
        registry.unregister(token: "va")
        #expect(registry.attributions.isEmpty)
        #expect(registry.required.isEmpty)
    }
}
