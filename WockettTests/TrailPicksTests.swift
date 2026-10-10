import Testing
import CloudKit
import CoreLocation
import Foundation
@testable import PoCSquat

/// Trail nominations and featured trails (2026-10-10): what a nomination
/// holds, one per person per trail, and which list rows a feature matches.
@MainActor
struct TrailPicksTests {

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    // MARK: Fixtures

    /// Google polyline encoding at the decoder's precision, for test geometry.
    private func encode(_ points: [(Double, Double)]) -> String {
        var out = ""
        var last = (0, 0)
        func push(_ value: Int) {
            var v = value < 0 ? ~(value << 1) : (value << 1)
            while v >= 0x20 {
                out.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (v & 0x1F)) + 63)))
                v >>= 5
            }
            out.unicodeScalars.append(UnicodeScalar(UInt8(v + 63)))
        }
        for (lat, lon) in points {
            let p = (Int((lat * 1e5).rounded()), Int((lon * 1e5).rounded()))
            push(p.0 - last.0)
            push(p.1 - last.1)
            last = p
        }
        return out
    }

    private func section(_ id: Int64, _ name: String?, key: String?, at lat: Double = 35.78, _ lon: Double = -78.64,
                         length: Double = 1_000) -> TrailFeature {
        TrailFeature(id: id, sourceID: "osm", sourceRef: "w\(id)", name: name,
                     encodedPolyline: encode([(lat, lon), (lat + 0.005, lon)]), pointCount: 2, lengthMeters: length,
                     bounds: TrailBounds(minLatitude: lat, minLongitude: lon, maxLatitude: lat + 0.005, maxLongitude: lon),
                     surface: nil, difficulty: nil, dogAccess: .unknown, dogAccessProvenance: .default,
                     allowsFoot: true, allowsBike: false, allowsHorse: false, isLoop: false, trailKey: key)
    }

    private func item(_ name: String, _ sections: [TrailFeature]) -> TrailListItem {
        TrailListItem(id: "i-\(name)", name: name, sections: sections, distanceMeters: 100)
    }

    private func feature(_ key: String, _ name: String, at lat: Double = 35.78, _ lon: Double = -78.64,
                         until: Date? = nil) -> FeaturedTrail {
        FeaturedTrail(trail: TrailRef(trailKey: key, trailName: name, region: "nc", latitude: lat, longitude: lon, lengthMeters: 1_000),
                      blurb: "Shady all afternoon", until: until)
    }

    // MARK: Trail identity

    @Test("A named trail's reference is its key, region, name, a point on its longest piece and its length")
    func reference() throws {
        let short = section(1, "Neuse River Trail", key: "nc:w1", at: 35.70, length: 300)
        let long = section(2, "Neuse River Trail", key: "nc:w1", at: 35.80, length: 2_000)
        let ref = try #require(TrailRef(item: item("Neuse River Trail", [short, long])))
        #expect(ref.trailKey == "nc:w1")
        #expect(ref.region == "nc")
        #expect(ref.trailName == "Neuse River Trail")
        #expect(abs(ref.latitude - 35.80) < 0.00001, "the longest piece's first point")
        #expect(ref.lengthMeters == 2_300)
    }

    @Test("Unnamed paths, and trails from packs without keys, can't be nominated")
    func noReference() {
        #expect(TrailRef(item: item("Footpath", [section(1, nil, key: nil)])) == nil)
        #expect(TrailRef(item: item("Old Trail", [section(1, "Old Trail", key: nil)])) == nil)
    }

    // MARK: Nominations

    @Test("A nomination holds the trail and the note, and nothing about the nominator")
    func nominationRecord() throws {
        let ref = try #require(TrailRef(item: item("Lake Loop", [section(1, "Lake Loop", key: "nc:w9")])))
        let record = TrailNominations.record(for: ref, note: "  Great views \n", nominator: "_me")
        #expect(record.recordType == "TrailNomination")
        #expect(record["trailKey"] as? String == "nc:w9")
        #expect(record["trailName"] as? String == "Lake Loop")
        #expect(record["region"] as? String == "nc")
        #expect(record["note"] as? String == "Great views")
        #expect(Set(record.allKeys()) == ["trailKey", "trailName", "region", "latitude", "longitude", "lengthMeters", "note"])
        #expect(!record.recordID.recordName.contains("_me"))
    }

    @Test("The note is kept to 300 characters")
    func noteCap() throws {
        let ref = try #require(TrailRef(item: item("Lake Loop", [section(1, "Lake Loop", key: "nc:w9")])))
        let record = TrailNominations.record(for: ref, note: String(repeating: "x", count: 400), nominator: nil)
        #expect((record["note"] as? String)?.count == 300)
    }

    @Test("One person and one trail make one record name; anyone else, or another trail, another")
    func oneNominationEach() {
        let a = TrailNominations.recordName(trailKey: "nc:w1", nominator: "_me")
        #expect(a == TrailNominations.recordName(trailKey: "nc:w1", nominator: "_me"))
        #expect(a != TrailNominations.recordName(trailKey: "nc:w1", nominator: "_you"))
        #expect(a != TrailNominations.recordName(trailKey: "nc:w2", nominator: "_me"))
        #expect(TrailNominations.recordName(trailKey: "nc:w1", nominator: nil)
                != TrailNominations.recordName(trailKey: "nc:w1", nominator: nil))
    }

    @Test("A second nomination is 'already nominated'; other errors say what to do")
    func outcomes() {
        #expect(TrailNominations.outcome(of: CKError(.serverRecordChanged)) == .alreadyNominated)
        #expect(TrailNominations.outcome(of: CKError(.notAuthenticated))
                == .failed("Sign in to iCloud in the Settings app to nominate a trail."))
        #expect(TrailNominations.outcome(of: CKError(.networkUnavailable))
                == .failed("Couldn't send your nomination. Check your connection and try again."))
        #expect(TrailNominations.outcome(of: CommunityAccessError.suspended(until: nil))
                == .failed(CommunityAccessError.suspended(until: nil).message))
    }

    private final class FakeNominations: TrailNominationStore {
        var saved: [CKRecord] = []
        var error: Error?
        func currentUserRecordName() async throws -> String { "_me" }
        func save(_ record: CKRecord) async throws {
            if let error { throw error }
            saved.append(record)
        }
    }

    private static let neverFires: OptimisticVote.Sleep = { _ in try await Task.sleep(for: .seconds(86_400)) }

    @Test("Sending saves once under the nominator's record name; a suspended account saves nothing")
    func submit() async throws {
        let ref = try #require(TrailRef(item: item("Lake Loop", [section(1, "Lake Loop", key: "nc:w9")])))
        let store = FakeNominations()
        let sent = await TrailNominationSubmission.submit(ref, note: "", store: store, canPost: {},
                                                          knownNominator: { nil }, sleep: Self.neverFires)
        #expect(sent == .sent)
        #expect(store.saved.first?.recordID.recordName == TrailNominations.recordName(trailKey: "nc:w9", nominator: "_me"))
        let paused = FakeNominations()
        let refused = await TrailNominationSubmission.submit(ref, note: "", store: paused,
                                                             canPost: { throw CommunityAccessError.suspended(until: nil) },
                                                             knownNominator: { nil }, sleep: Self.neverFires)
        #expect(refused == .failed(CommunityAccessError.suspended(until: nil).message))
        #expect(paused.saved.isEmpty)
    }

    // MARK: Featured

    @Test("A feature matches its trail by key")
    func matchByKey() {
        let row = item("Neuse River Trail", [section(1, "Neuse River Trail", key: "nc:w1")])
        #expect(FeaturedTrails.match(row, in: [feature("nc:w1", "Different Name")], at: now) != nil)
        #expect(FeaturedTrails.match(row, in: [feature("nc:w2", "Other Trail")], at: now) == nil)
    }

    @Test("After a rebuild changes the key, the same name close by still matches; a namesake far away doesn't")
    func matchByNameNearby() {
        let row = item("Lake Loop", [section(1, "Lake Loop", key: "nc:w5", at: 35.78, -78.64)])
        #expect(FeaturedTrails.match(row, in: [feature("nc:w1", "lake loop ", at: 35.785, -78.64)], at: now) != nil)
        #expect(FeaturedTrails.match(row, in: [feature("nc:w1", "Lake Loop", at: 35.95, -78.64)], at: now) == nil,
                "about 19 km away: another Lake Loop")
    }

    @Test("An ended feature matches nothing; one with no end always does")
    func expiry() {
        let row = item("Neuse River Trail", [section(1, "Neuse River Trail", key: "nc:w1")])
        #expect(FeaturedTrails.match(row, in: [feature("nc:w1", "N", until: now.addingTimeInterval(-1))], at: now) == nil)
        #expect(FeaturedTrails.match(row, in: [feature("nc:w1", "N", until: now.addingTimeInterval(60))], at: now) != nil)
        #expect(FeaturedTrails.match(row, in: [feature("nc:w1", "N", until: nil)], at: now) != nil)
    }

    @Test("Featured rows keep the list's order")
    func featuredItems() {
        let a = item("A Trail", [section(1, "A Trail", key: "nc:w1")])
        let b = item("B Trail", [section(2, "B Trail", key: "nc:w2")])
        let c = item("C Trail", [section(3, "C Trail", key: "nc:w3")])
        let list = [a, b, c]
        let picks = FeaturedTrails.featuredItems(list, in: [feature("nc:w3", "C"), feature("nc:w1", "A")], at: now)
        #expect(picks.map(\.item.id) == [a.id, c.id])
        // That "Trails near you" keeps every row is held by the view, which
        // lists finder.items as they are; nothing here could show it.
    }

    @Test("With sections listed separately, a featured trail shows once, at its nearest piece")
    func featuredOnce() {
        let rows = (1...3).map { i in TrailListItem(id: "s\(i)", name: "Neuse River Trail",
                                                    sections: [section(Int64(i), "Neuse River Trail", key: "nc:w1")],
                                                    distanceMeters: Double(i) * 100) }
        let picks = FeaturedTrails.featuredItems(rows, in: [feature("nc:w1", "Neuse River Trail")], at: now)
        #expect(picks.map(\.item.id) == ["s1"])
    }

    @Test("A one-section row and the grouped row describe the trail the same way")
    func wholeTrailReference() throws {
        let a = section(1, "Neuse River Trail", key: "nc:w1", at: 35.70, length: 300)
        let b = section(2, "Neuse River Trail", key: "nc:w1", at: 35.80, length: 2_000)
        let whole: (String) -> [TrailFeature] = { $0 == "nc:w1" ? [a, b] : [] }
        let grouped = try #require(TrailRef(item: item("Neuse River Trail", [a, b]), wholeTrail: whole))
        let oneSection = try #require(TrailRef(item: item("Neuse River Trail", [a]), wholeTrail: whole))
        #expect(oneSection == grouped)
        #expect(oneSection.lengthMeters == 2_300)
        #expect(TrailRef.canNominate(item("Neuse River Trail", [a])))
        #expect(!TrailRef.canNominate(item("Footpath", [section(3, nil, key: nil)])))
    }

    @Test("A FeaturedTrail record reads with its blurb and end")
    func featuredRecord() throws {
        let record = CKRecord(recordType: "FeaturedTrail", recordID: CKRecord.ID(recordName: "featured.nc.w1"))
        TrailRef(trailKey: "nc:w1", trailName: "Lake Loop", region: "nc", latitude: 35, longitude: -78, lengthMeters: 900)
            .write(to: record)
        record["blurb"] = "  Shady  "
        record["until"] = now
        let read = try #require(FeaturedTrails.featured(from: record))
        #expect(read.blurb == "Shady")
        #expect(read.until == now)
        #expect(read.trail.trailKey == "nc:w1")
        record["trailKey"] = nil
        #expect(FeaturedTrails.featured(from: record) == nil)
    }

    // MARK: Featured list refresh

    private final class FakeFeatured: FeaturedTrailStore {
        var list: [FeaturedTrail] = []
        var error: Error?
        var calls = 0
        var holds = false
        var gate: CheckedContinuation<Void, Never>?
        func featured() async throws -> [FeaturedTrail] {
            calls += 1
            if holds { await withCheckedContinuation { gate = $0 } }
            await Task.yield()
            if let error { throw error }
            return list
        }
    }

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func defaults() -> UserDefaults {
        let name = "TrailPicksTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name) ?? .standard
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Fetched at most every 30 minutes, kept across launches, and a failure keeps what's held")
    func refresh() async {
        let fake = FakeFeatured()
        fake.list = [feature("nc:w1", "A")]
        let clock = Clock(now)
        let d = defaults()
        let service = FeaturedTrailService(store: fake, defaults: d, now: { clock.now }, sleep: Self.neverFires)
        await service.refreshIfStale()
        #expect(service.list == fake.list)
        clock.now = now.addingTimeInterval(1_799)
        await service.refreshIfStale()
        #expect(fake.calls == 1)
        let relaunched = FeaturedTrailService(store: FakeFeatured(), defaults: d, sleep: Self.neverFires)
        #expect(relaunched.list == fake.list, "offline after a relaunch still shows them")
        fake.error = CKError(.networkUnavailable)
        clock.now = now.addingTimeInterval(1_800)
        await service.refreshIfStale()
        #expect(fake.calls == 2)
        #expect(service.list == [feature("nc:w1", "A")])
    }

    /// Yields until `condition` holds, for up to 30 s of wall time.
    private func waitUntil(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(30)
        while !condition(), Date() < end { await Task.yield() }
    }

    @Test("The list waits no longer than the deadline; a slow fetch still lands for next time")
    func deadline() async {
        let fake = FakeFeatured()
        fake.holds = true
        fake.list = [feature("nc:w1", "A")]
        var waited: Duration?
        let service = FeaturedTrailService(store: fake, defaults: defaults(), now: { now }, sleep: { waited = $0 })
        await service.refreshIfStale()
        #expect(waited == .seconds(3))
        #expect(service.list.isEmpty, "this time the list went ahead without it")
        await waitUntil { fake.gate != nil }
        fake.gate?.resume()
        await waitUntil { !service.list.isEmpty }
        #expect(service.list == fake.list)
    }

    @Test("After a failed fetch, the next try waits a minute, not half an hour")
    func retryAfterFailure() async {
        let fake = FakeFeatured()
        fake.error = CKError(.networkUnavailable)
        let clock = Clock(now)
        let service = FeaturedTrailService(store: fake, defaults: defaults(), now: { clock.now }, sleep: Self.neverFires)
        await service.refreshIfStale()
        clock.now = now.addingTimeInterval(59)
        await service.refreshIfStale()
        #expect(fake.calls == 1)
        clock.now = now.addingTimeInterval(60)
        await service.refreshIfStale()
        #expect(fake.calls == 2)
    }
}
