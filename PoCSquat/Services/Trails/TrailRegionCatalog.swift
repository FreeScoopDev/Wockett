import CloudKit
import Foundation

// MARK: - Region catalogue
//
// Where downloadable region packs come from. CloudKit's public database is the
// distribution channel because it is already in the stack — no new account,
// no API key, no third-party service that can change its terms — and the
// free allowance scales with active users. Each region is one `TrailRegionPack`
// record: metadata fields plus the pack file as a `CKAsset`.
//
// Two rules from the trails spec apply here:
//   1. Publish a new pack only when the data materially changed, never per
//      release — a device downloads a region only when its `packVersion`
//      moved, and CloudKit transfer is billed per byte.
//   2. A pack whose `schemaVersion` this build cannot read is listed as
//      "needs an app update", not downloaded and then refused.

/// One row of the catalogue — what the console record says about a region.
struct TrailRegionRecord: Identifiable, Hashable {
    let region: String
    let regionName: String
    let schemaVersion: Int
    let packVersion: Int
    let builtAt: Date?
    let trailCount: Int
    let sizeBytes: Int64
    /// The CloudKit record to fetch the asset from.
    let recordName: String

    var id: String { region }

    /// Whether this build can read the pack without downloading it first.
    var isReadable: Bool { BundledTrailSource.supportedSchemaVersions.contains(schemaVersion) }
}

/// The seam over CloudKit, so the install flow is testable without a network
/// or an iCloud entitlement — CI has neither.
protocol TrailRegionRemote: AnyObject {
    /// Every region in the catalogue, unordered.
    func availableRegions() async throws -> [TrailRegionRecord]
    /// Downloads the pack for `record` and returns a temporary file URL the
    /// caller owns. Progress is reported as 0...1 when the transport can.
    func downloadPack(_ record: TrailRegionRecord, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// CloudKit implementation. Reads only; publishing packs is a console job.
final class CloudKitTrailRegionRemote: TrailRegionRemote {

    static let recordType = "TrailRegionPack"

    private let database: CKDatabase

    init(database: CKDatabase = CKContainer(identifier: "iCloud.Scoops.PoCSquat").publicCloudDatabase) {
        self.database = database
    }

    func availableRegions() async throws -> [TrailRegionRecord] {
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true))
        // Everything but the asset: listing must not download packs.
        let keys = ["region", "regionName", "schemaVersion", "packVersion", "builtAt", "trailCount", "sizeBytes"]
        let (results, _) = try await database.records(matching: query, desiredKeys: keys, resultsLimit: 100)
        return results.compactMap { _, result -> TrailRegionRecord? in
            guard let record = try? result.get() else { return nil }
            return Self.parse(record)
        }
    }

    func downloadPack(_ record: TrailRegionRecord, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let id = CKRecord.ID(recordName: record.recordName)
        let fetched = try await database.record(for: id)
        guard let asset = fetched["pack"] as? CKAsset, let source = asset.fileURL else {
            throw TrailPackError.malformed(detail: "TrailRegionPack \(record.region) has no pack asset")
        }
        // CloudKit's asset file is temporary; move it somewhere we own before
        // the record is released.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(record.region)-\(record.packVersion)-\(UUID().uuidString).wktpack")
        try FileManager.default.copyItem(at: source, to: destination)
        progress(1)
        return destination
    }

    static func parse(_ record: CKRecord) -> TrailRegionRecord? {
        guard let region = record["region"] as? String, !region.isEmpty,
              let schema = record["schemaVersion"] as? Int,
              let packVersion = record["packVersion"] as? Int else { return nil }
        return TrailRegionRecord(
            region: region,
            regionName: record["regionName"] as? String ?? region.uppercased(),
            schemaVersion: schema,
            packVersion: packVersion,
            builtAt: record["builtAt"] as? Date,
            trailCount: record["trailCount"] as? Int ?? 0,
            sizeBytes: (record["sizeBytes"] as? Int64) ?? Int64(record["sizeBytes"] as? Int ?? 0),
            recordName: record.recordID.recordName
        )
    }
}
