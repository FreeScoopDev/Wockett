import CoreLocation
import Foundation
import SQLite3

// MARK: - BundledTrailSource
//
// Reads a `.wktpack` region pack — a plain SQLite file with an R*Tree over
// each trail's bounding box — through the SQLite that ships in iOS. No
// SpatiaLite, no wrapper library: the zero-dependency rule holds, and R*Tree
// is compiled into the system library. "Trails near me" against the 74,000-row
// North Carolina pack measured 0.87 ms.
//
// Opened read-only. A pack is data the app ships or downloads, never something
// it writes to; a refresh is a new file, not an edit.

final class BundledTrailSource: TrailDataSource {

    /// Schema versions this build can read. Widen the range when the reader
    /// learns a new version; never read a version outside it.
    static let supportedSchemaVersions: ClosedRange<Int> = 1...1

    let packInfo: TrailPackInfo
    let attributions: [TrailAttribution]

    private let db: OpaquePointer
    private let url: URL

    /// Opens the pack at `url`, or throws a `TrailPackError` saying why.
    init(url: URL) throws {
        self.url = url
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
            if let handle { sqlite3_close(handle) }
            throw TrailPackError.cannotOpen(path: url.path, detail: detail)
        }
        db = handle

        do {
            let meta = try Self.readMeta(db)
            guard let schemaText = meta["schema_version"], let schema = Int(schemaText) else {
                throw TrailPackError.malformed(detail: "meta.schema_version missing")
            }
            guard Self.supportedSchemaVersions.contains(schema) else {
                throw TrailPackError.unsupportedSchema(found: schema, supported: Self.supportedSchemaVersions)
            }
            guard let region = meta["region"], let regionName = meta["region_name"] else {
                throw TrailPackError.malformed(detail: "meta.region / region_name missing")
            }
            packInfo = TrailPackInfo(
                schemaVersion: schema,
                builderVersion: meta["builder_version"] ?? "",
                region: region,
                regionName: regionName,
                builtAt: meta["built_at"].flatMap { ISO8601DateFormatter().date(from: $0) },
                trailCount: meta["trail_count"].flatMap(Int.init) ?? 0,
                sourceIDs: (meta["sources"] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            )
            attributions = try Self.readAttributions(db)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: Queries

    func trails(near center: CLLocationCoordinate2D,
                radiusMeters: Double,
                matching query: TrailQuery = .any,
                limit: Int = 50) throws -> [TrailFeature] {
        let box = TrailBounds.around(center, radiusMeters: radiusMeters)
        // Every trail whose box touches the search area is a candidate, and
        // every candidate is ranked by real distance. There is deliberately no
        // cap on the index scan: a bounding-box hit is not a distance, and a
        // capped scan in R*Tree order hands back an arbitrary subset — downtown
        // Raleigh has 287 trails inside a 2 km box, and a cap of 200 lost the
        // 25 nearest. A box scan of a few thousand rows is sub-millisecond.
        let candidates = try boxQuery(box, matching: query, limit: nil)
        return candidates
            .map { ($0, Self.distanceMeters(from: center, to: $0)) }
            .filter { $0.1 <= radiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    func trails(in bounds: TrailBounds,
                matching query: TrailQuery = .any,
                limit: Int = 200) throws -> [TrailFeature] {
        try boxQuery(bounds, matching: query, limit: limit)
    }

    /// The R*Tree scan both public queries share. `limit: nil` scans the whole
    /// box; the near-me path needs that, because a partial scan has no order.
    private func boxQuery(_ bounds: TrailBounds, matching query: TrailQuery, limit: Int?) throws -> [TrailFeature] {
        var sql = """
            SELECT t.* FROM trails t
            JOIN trails_rtree r ON r.id = t.id
            WHERE r.min_lat <= ? AND r.max_lat >= ? AND r.min_lon <= ? AND r.max_lon >= ?
            """
        var binds: [Bind] = [.real(bounds.maxLatitude), .real(bounds.minLatitude),
                             .real(bounds.maxLongitude), .real(bounds.minLongitude)]
        Self.append(query, to: &sql, binds: &binds)
        if let limit {
            sql += " LIMIT ?"
            binds.append(.int(Int64(limit)))
        }
        return try run(sql, binds: binds)
    }

    func trail(id: Int64) throws -> TrailFeature? {
        try run("SELECT * FROM trails WHERE id = ?", binds: [.int(id)]).first
    }

    // MARK: Query building

    private enum Bind {
        case real(Double)
        case int(Int64)
        case text(String)
    }

    /// Adds `query`'s filters as `AND` clauses. Every value is bound, never
    /// interpolated — `nameContains` is user input.
    private static func append(_ query: TrailQuery, to sql: inout String, binds: inout [Bind]) {
        if let dog = query.dogAccess, !dog.isEmpty {
            let sorted = dog.map(\.rawValue).sorted()
            sql += " AND t.dog_access IN (\(sorted.map { _ in "?" }.joined(separator: ",")))"
            binds += sorted.map(Bind.text)
        }
        if let min = query.minLengthMeters {
            sql += " AND t.length_m >= ?"; binds.append(.real(min))
        }
        if let max = query.maxLengthMeters {
            sql += " AND t.length_m <= ?"; binds.append(.real(max))
        }
        if let surfaces = query.surfaces, !surfaces.isEmpty {
            let sorted = surfaces.sorted()
            sql += " AND t.surface IN (\(sorted.map { _ in "?" }.joined(separator: ",")))"
            binds += sorted.map(Bind.text)
        }
        if let bike = query.allowsBike {
            sql += " AND t.allows_bike = ?"; binds.append(.int(bike ? 1 : 0))
        }
        if query.loopsOnly {
            sql += " AND t.is_loop = 1"
        }
        if let needle = query.nameContains?.trimmingCharacters(in: .whitespacesAndNewlines), !needle.isEmpty {
            sql += " AND t.name LIKE ? ESCAPE '\\'"
            let escaped = needle.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            binds.append(.text("%\(escaped)%"))
        }
    }

    // MARK: SQLite plumbing

    private func run(_ sql: String, binds: [Bind]) throws -> [TrailFeature] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw TrailPackError.queryFailed(detail: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for (i, bind) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch bind {
            case .real(let v): sqlite3_bind_double(stmt, idx, v)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            }
        }

        // Column lookup by name, so a reordered SELECT cannot silently swap
        // fields — `SELECT t.*` column order is the pack's, not ours.
        var columns: [String: Int32] = [:]
        for i in 0..<sqlite3_column_count(stmt) {
            columns[String(cString: sqlite3_column_name(stmt, i))] = i
        }
        func text(_ name: String) -> String? {
            guard let i = columns[name], sqlite3_column_type(stmt, i) != SQLITE_NULL,
                  let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func real(_ name: String) -> Double { columns[name].map { sqlite3_column_double(stmt, $0) } ?? 0 }
        func int(_ name: String) -> Int64 { columns[name].map { sqlite3_column_int64(stmt, $0) } ?? 0 }

        var rows: [TrailFeature] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw TrailPackError.queryFailed(detail: String(cString: sqlite3_errmsg(db)))
            }
            rows.append(TrailFeature(
                id: int("id"),
                sourceID: text("source_id") ?? "",
                sourceRef: text("source_ref") ?? "",
                name: text("name").flatMap { $0.isEmpty ? nil : $0 },
                encodedPolyline: text("polyline") ?? "",
                pointCount: Int(int("point_count")),
                lengthMeters: real("length_m"),
                bounds: TrailBounds(minLatitude: real("min_lat"), minLongitude: real("min_lon"),
                                    maxLatitude: real("max_lat"), maxLongitude: real("max_lon")),
                surface: text("surface").flatMap { $0.isEmpty ? nil : $0 },
                difficulty: text("difficulty").flatMap { $0.isEmpty ? nil : $0 },
                dogAccess: DogAccess(rawValue: text("dog_access") ?? "") ?? .unknown,
                dogAccessProvenance: DogAccessProvenance(rawValue: text("dog_access_provenance") ?? "") ?? .default,
                allowsFoot: int("allows_foot") != 0,
                allowsBike: int("allows_bike") != 0,
                allowsHorse: int("allows_horse") != 0,
                isLoop: int("is_loop") != 0
            ))
        }
        return rows
    }

    private static func readMeta(_ db: OpaquePointer) throws -> [String: String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM meta", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw TrailPackError.malformed(detail: "no meta table: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        var meta: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let k = sqlite3_column_text(stmt, 0), let v = sqlite3_column_text(stmt, 1) else { continue }
            meta[String(cString: k)] = String(cString: v)
        }
        return meta
    }

    private static func readAttributions(_ db: OpaquePointer) throws -> [TrailAttribution] {
        var stmt: OpaquePointer?
        let sql = "SELECT source_id, name, attribution, license, url, requires_attribution FROM attribution ORDER BY rowid"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw TrailPackError.malformed(detail: "no attribution table: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [TrailAttribution] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ i: Int32) -> String? {
                guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
                return String(cString: c)
            }
            rows.append(TrailAttribution(
                sourceID: col(0) ?? "",
                name: col(1) ?? "",
                attribution: col(2) ?? "",
                license: col(3) ?? "",
                url: col(4).flatMap(URL.init(string:)),
                requiresAttribution: sqlite3_column_int(stmt, 5) != 0
            ))
        }
        return rows
    }

    /// Distance from `origin` to the nearest point on the trail's line — on a
    /// segment, not merely at a vertex. The pack simplifies geometry at ~2 m,
    /// which removes every interior vertex on a straight run: 13,123 of North
    /// Carolina's 73,959 trails are exactly two points, and a 3 km greenway is
    /// one segment. Nearest-vertex distance put a user standing on its midpoint
    /// 1.5 km away. Greenways and rail-trails — the straightest trails, and the
    /// ones a walking app most wants — were the worst affected.
    ///
    /// Computed in a local equirectangular frame around `origin`: metres north
    /// and east, with east scaled by cos(latitude). Accurate to well under a
    /// percent at the radii this serves (tens of kilometres), and it needs no
    /// `CLLocation` allocation per vertex.
    static func distanceMeters(from origin: CLLocationCoordinate2D, to trail: TrailFeature) -> Double {
        let coords = trail.coordinates
        guard let first = coords.first else { return .greatestFiniteMagnitude }
        let metersPerDegree = 111_320.0
        let cosLat = cos(origin.latitude * .pi / 180)
        func local(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            ((c.longitude - origin.longitude) * metersPerDegree * cosLat,
             (c.latitude - origin.latitude) * metersPerDegree)
        }
        var prev = local(first)
        var best = (prev.x * prev.x + prev.y * prev.y).squareRoot()
        for c in coords.dropFirst() {
            let cur = local(c)
            let dx = cur.x - prev.x, dy = cur.y - prev.y
            let lengthSquared = dx * dx + dy * dy
            // Projection of the origin (0,0) onto the segment, clamped to it.
            let t = lengthSquared > 0 ? max(0, min(1, -(prev.x * dx + prev.y * dy) / lengthSquared)) : 0
            let px = prev.x + t * dx, py = prev.y + t * dy
            best = min(best, (px * px + py * py).squareRoot())
            prev = cur
        }
        return best
    }

    /// SQLite's `SQLITE_TRANSIENT`: the C macro does not import, so it is
    /// spelled out. Tells SQLite to copy bound text before the call returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
