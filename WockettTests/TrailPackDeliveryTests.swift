import Testing
import Foundation
@testable import PoCSquat

/// The download/install flow of `TrailPackLibrary`, driven through the
/// `TrailRegionRemote` seam — CI has no network and no iCloud entitlement,
/// so CloudKit itself is verified by hand on a device, not here. What is
/// pinned here is everything that happens after the bytes arrive: a bad
/// pack never replaces a good one, removal falls back to the bundled copy,
/// the manifest survives a relaunch, and unreadable schemas are refused
/// before a byte is downloaded.
@MainActor
struct TrailPackDeliveryTests {

    private final class Marker {}

    /// A remote that serves the fixture pack (or any file) for any region.
    private final class FakeRemote: TrailRegionRemote {
        var regions: [TrailRegionRecord]
        var fileToServe: URL?
        var listError: Error?
        var downloads = 0
        init(regions: [TrailRegionRecord], fileToServe: URL?) { self.regions = regions; self.fileToServe = fileToServe }
        func availableRegions() async throws -> [TrailRegionRecord] {
            if let listError { throw listError }
            return regions
        }
        func downloadPack(_ record: TrailRegionRecord, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
            downloads += 1
            guard let fileToServe else { throw TrailPackError.malformed(detail: "nothing to serve") }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wktpack")
            try FileManager.default.copyItem(at: fileToServe, to: temp)
            progress(1)
            return temp
        }
    }

    private struct Failure: Error {}

    private var fixtureURL: URL {
        get throws { try #require(Bundle(for: Marker.self).url(forResource: "fixture", withExtension: "wktpack")) }
    }

    private func record(_ region: String, version: Int = 1, schema: Int = 1) -> TrailRegionRecord {
        TrailRegionRecord(region: region, regionName: region.uppercased(), schemaVersion: schema,
                          packVersion: version, builtAt: nil, trailCount: 6, sizeBytes: 53_248,
                          recordName: "rec-\(region)")
    }

    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TrailPackDeliveryTests-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: Catalogue

    @Test("Catalogue states: bundled, available, installed, update, needs app update")
    func states() async throws {
        let remote = FakeRemote(regions: [record("nc"), record("va"), record("zz", schema: 99)], fileToServe: try fixtureURL)
        let library = TrailPackLibrary(registry: TrailAttributionRegistry(), remote: remote, packsDirectory: scratchDirectory())
        await library.refreshCatalog()
        #expect(library.catalog.map(\.region) == ["nc", "va", "zz"])
        #expect(library.catalogError == nil)
        #expect(library.state(of: record("nc")) == .bundled)
        #expect(library.state(of: record("va")) == .available)
        #expect(library.state(of: record("zz", schema: 99)) == .needsAppUpdate)

        await library.download(record("va"))
        #expect(library.state(of: record("va")) == .installed(packVersion: 1))
        #expect(library.state(of: record("va", version: 2)) == .updateAvailable(installed: 1, latest: 2))
    }

    @Test("A catalogue error is recorded, not thrown")
    func catalogError() async {
        let remote = FakeRemote(regions: [], fileToServe: nil)
        remote.listError = Failure()
        let library = TrailPackLibrary(registry: TrailAttributionRegistry(), remote: remote, packsDirectory: scratchDirectory())
        await library.refreshCatalog()
        #expect(library.catalogError != nil)
        #expect(library.catalog.isEmpty)
    }

    // MARK: Install

    @Test("Downloading installs the pack, opens it, credits it, and persists the manifest")
    func downloadInstalls() async throws {
        let dir = scratchDirectory()
        let registry = TrailAttributionRegistry()
        let remote = FakeRemote(regions: [record("va")], fileToServe: try fixtureURL)
        let library = TrailPackLibrary(registry: registry, remote: remote, packsDirectory: dir)

        await library.download(record("va", version: 3))
        #expect(remote.downloads == 1)
        #expect(library.source(for: "va") != nil)
        #expect(library.installed == ["va": 3])
        #expect(FileManager.default.fileExists(atPath: library.packURL(for: "va").path))
        #expect(registry.attributions.map(\.sourceID) == ["osm"])

        // A fresh library over the same directory sees the install.
        let relaunched = TrailPackLibrary(registry: TrailAttributionRegistry(), remote: remote, packsDirectory: dir)
        #expect(relaunched.installed == ["va": 3])
        relaunched.loadBundled(from: Bundle(for: Marker.self))  // test bundle has no nc; va comes from disk
        #expect(relaunched.source(for: "va") != nil)
    }

    @Test("A download that is not a readable pack is discarded and the previous pack stays")
    func badDownloadIsDiscarded() async throws {
        let dir = scratchDirectory()
        let registry = TrailAttributionRegistry()
        let remote = FakeRemote(regions: [record("va")], fileToServe: try fixtureURL)
        let library = TrailPackLibrary(registry: registry, remote: remote, packsDirectory: dir)
        await library.download(record("va", version: 1))
        let good = try #require(library.source(for: "va"))

        // Now serve garbage for the "update".
        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wktpack")
        try Data("not a database".utf8).write(to: garbage)
        remote.fileToServe = garbage
        await library.download(record("va", version: 2))

        #expect(library.source(for: "va") === good, "the good pack was never closed")
        #expect(library.installed == ["va": 1])
        if case .failed = library.state(of: record("va", version: 2)) {} else {
            Issue.record("expected .failed, got \(library.state(of: record("va", version: 2)))")
        }
    }

    @Test("An unreadable schema is refused before anything is downloaded")
    func unreadableSchemaNotDownloaded() async throws {
        let remote = FakeRemote(regions: [], fileToServe: try fixtureURL)
        let library = TrailPackLibrary(registry: TrailAttributionRegistry(), remote: remote, packsDirectory: scratchDirectory())
        await library.download(record("zz", schema: BundledTrailSource.supportedSchemaVersions.upperBound + 1))
        #expect(remote.downloads == 0)
        #expect(library.source(for: "zz") == nil)
    }

    // MARK: Remove

    @Test("Removing an install deletes the file and forgets it; a bundled region falls back to its bundled pack")
    func removeFallsBack() async throws {
        let dir = scratchDirectory()
        let registry = TrailAttributionRegistry()
        let remote = FakeRemote(regions: [], fileToServe: try fixtureURL)
        let library = TrailPackLibrary(registry: registry, remote: remote, packsDirectory: dir)

        // "nc" is a bundled region; the test bundle lacks it, so the fallback
        // has nothing to reopen — that is what an unbundled region looks like.
        await library.download(record("va"))
        library.remove(region: "va")
        #expect(library.source(for: "va") == nil)
        #expect(library.installed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.packURL(for: "va").path))
        #expect(registry.attributions.isEmpty)

        // Against the real app bundle, removing the "nc" download reopens the
        // bundled trimmed pack.
        let real = TrailPackLibrary(registry: TrailAttributionRegistry(), remote: remote, packsDirectory: scratchDirectory())
        real.loadBundled(from: .main)
        let bundledCount = try #require(real.source(for: "nc")).packInfo.trailCount
        await real.download(record("nc", version: 1))
        #expect(try #require(real.source(for: "nc")).packInfo.trailCount == 6, "the download (fixture) replaced the bundled pack")
        real.remove(region: "nc")
        #expect(try #require(real.source(for: "nc")).packInfo.trailCount == bundledCount, "bundled pack is back")
    }

    // MARK: CloudKit record parsing

    @Test("Parses a TrailRegionPack record and rejects one missing required fields")
    func parsesRecord() throws {
        let rec = CKRecordFixture.make(region: "va", regionName: "Virginia", schema: 1, packVersion: 4,
                                       trailCount: 12_000, sizeBytes: 30_000_000)
        let parsed = try #require(CloudKitTrailRegionRemote.parse(rec))
        #expect(parsed.region == "va")
        #expect(parsed.regionName == "Virginia")
        #expect(parsed.packVersion == 4)
        #expect(parsed.sizeBytes == 30_000_000)
        #expect(parsed.isReadable)

        let missing = CKRecordFixture.make(region: "", regionName: "x", schema: 1, packVersion: 1, trailCount: 0, sizeBytes: 0)
        #expect(CloudKitTrailRegionRemote.parse(missing) == nil)
    }
}

import CloudKit

private enum CKRecordFixture {
    static func make(region: String, regionName: String, schema: Int, packVersion: Int,
                     trailCount: Int, sizeBytes: Int64) -> CKRecord {
        let record = CKRecord(recordType: CloudKitTrailRegionRemote.recordType, recordID: CKRecord.ID(recordName: "rec-\(region)"))
        record["region"] = region as CKRecordValue
        record["regionName"] = regionName as CKRecordValue
        record["schemaVersion"] = schema as CKRecordValue
        record["packVersion"] = packVersion as CKRecordValue
        record["trailCount"] = trailCount as CKRecordValue
        record["sizeBytes"] = sizeBytes as CKRecordValue
        return record
    }
}
