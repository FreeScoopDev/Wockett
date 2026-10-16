import Testing
import CloudKit
import CoreLocation
import Foundation
@testable import PoCSquat

/// Trail nominations and featured trails (2026-10-10): what a nomination
/// holds, and which list rows a feature matches. Claim tokens and the
/// one-per-trail rule: ContributionStatusTests.
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

    @Test("A nomination holds the trail, the note and its claim token, and nothing about the nominator")
    func nominationRecord() throws {
        let ref = try #require(TrailRef(item: item("Lake Loop", [section(1, "Lake Loop", key: "nc:w9")])))
        let record = TrailNominations.record(for: ref, note: "  Great views \n", claimToken: "T")
        #expect(record.recordType == "TrailNomination")
        #expect(record["trailKey"] as? String == "nc:w9")
        #expect(record["trailName"] as? String == "Lake Loop")
        #expect(record["region"] as? String == "nc")
        #expect(record["note"] as? String == "Great views")
        #expect(record["claimToken"] as? String == "T")
        #expect(Set(record.allKeys()) == ["trailKey", "trailName", "region", "latitude", "longitude", "lengthMeters", "note", "claimToken"])
        #expect(record.recordID.recordName.hasPrefix("nomination."))
    }

    @Test("The note is kept to 300 characters")
    func noteCap() throws {
        let ref = try #require(TrailRef(item: item("Lake Loop", [section(1, "Lake Loop", key: "nc:w9")])))
        let record = TrailNominations.record(for: ref, note: String(repeating: "x", count: 400), claimToken: "T")
        #expect((record["note"] as? String)?.count == 300)
    }

    @Test("A clash is 'already nominated'; other errors say what to do")
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
        func save(_ record: CKRecord) async throws {
            if let error { throw error }
            saved.append(record)
        }
    }

    private static let neverFires: OptimisticVote.Sleep = { _ in try await Task.sleep(for: .seconds(86_400)) }

    private func contributions() throws -> ContributionService {
        let suite = "wkt.tests.trailPicks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return ContributionService(store: NoContributionStatusStore(), defaults: defaults)
    }

    @Test("Sending saves once; a suspended account saves nothing")
    func submit() async throws {
        let ref = try #require(TrailRef(item: item("Lake Loop", [section(1, "Lake Loop", key: "nc:w9")])))
        let store = FakeNominations()
        let sent = await TrailNominationSubmission.submit(ref, note: "", store: store, contributions: try contributions(),
                                                          canPost: {}, sleep: Self.neverFires)
        #expect(sent == .sent)
        #expect(store.saved.count == 1)
        #expect(store.saved.first?.recordID.recordName.hasPrefix("nomination.") == true)
        let paused = FakeNominations()
        let refused = await TrailNominationSubmission.submit(ref, note: "", store: paused, contributions: try contributions(),
                                                             canPost: { throw CommunityAccessError.suspended(until: nil) },
                                                             sleep: Self.neverFires)
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

    @Test("A feature goes to the trail with its key, not a nearer namesake")
    func keyBeatsNamesake() {
        let namesake = TrailListItem(id: "x", name: "Lake Trail", sections: [section(9, "Lake Trail", key: "nc:w9")], distanceMeters: 100)
        let real = TrailListItem(id: "y", name: "Lake Trail", sections: [section(1, "Lake Trail", key: "nc:w1", at: 35.79)], distanceMeters: 500)
        let picks = FeaturedTrails.featuredItems([namesake, real], in: [feature("nc:w1", "Lake Trail")], at: now)
        #expect(picks.map(\.item.id) == ["y"])
    }

    @Test("After a rebuild changed the key, the trail is found by name within reach")
    func nameFallbackAfterRebuild() {
        let rebuilt = TrailListItem(id: "r", name: "Lake Trail", sections: [section(5, "Lake Trail", key: "nc:w5")], distanceMeters: 100)
        let picks = FeaturedTrails.featuredItems([rebuilt], in: [feature("nc:w1", "Lake Trail")], at: now) { _ in false }
        #expect(picks.map(\.item.id) == ["r"])
    }

    @Test("A featured trail only filtered out of the list gives no card to a namesake")
    func filteredOutNoCard() {
        let namesake = TrailListItem(id: "x", name: "Lake Trail", sections: [section(9, "Lake Trail", key: "nc:w9")], distanceMeters: 100)
        let picks = FeaturedTrails.featuredItems([namesake], in: [feature("nc:w1", "Lake Trail")], at: now) { $0 == "nc:w1" }
        #expect(picks.isEmpty, "nc:w1 is still in the pack: it was filtered, not renamed")
    }

    @Test("A row carrying two featured keys shows the feature listed first, every time")
    func twoKeysOneRow() {
        let row = TrailListItem(id: "m", name: "Swamp Rabbit Trail",
                                sections: [section(1, "Swamp Rabbit Trail", key: "nc:w1"), section(2, "Swamp Rabbit Trail", key: "nc:w2")],
                                distanceMeters: 100)
        var b = feature("nc:w2", "Swamp Rabbit Trail")
        b = FeaturedTrail(trail: b.trail, blurb: "B note", until: nil)
        var a = feature("nc:w1", "Swamp Rabbit Trail")
        a = FeaturedTrail(trail: a.trail, blurb: "A note", until: nil)
        for _ in 0..<20 {
            #expect(FeaturedTrails.featuredItems([row], in: [b, a], at: now).map(\.feature.blurb) == ["B note"])
        }
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
        private var heldWaiters: [CheckedContinuation<Void, Never>] = []
        /// Returns once the fetch is being held: an event, not a poll.
        func held() async {
            if gate != nil { return }
            await withCheckedContinuation { heldWaiters.append($0) }
        }
        private func hold() async {
            await withCheckedContinuation { c in
                gate = c
                let waiting = heldWaiters
                heldWaiters = []
                waiting.forEach { $0.resume() }
            }
        }
        func featured() async throws -> [FeaturedTrail] {
            calls += 1
            if holds { await hold() }
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


    /// The deadline itself is driven by the injected sleep, which returns at
    /// once, so a correct refreshIfStale finishes as soon as the main actor
    /// runs it, with the fetch still held: `list.isEmpty` proves that order.
    /// Without the deadline it would wait for ever on the held fetch, so the
    /// test also needs a hang guard. That guard is wall time, and wall time
    /// includes time queued behind other main-actor tests: one minute fired
    /// on a correct build on a loaded CI machine (PR 196, 2026-10-12, with
    /// every deadline test taking 137-161 s), as `.timeLimit` did on PR 186.
    /// So it is five minutes: it only has to tell a hang from a slow machine.
    @Test("The list waits no longer than the deadline; a slow fetch still lands for next time")
    func deadline() async {
        let fake = FakeFeatured()
        fake.holds = true
        fake.list = [feature("nc:w1", "A")]
        var waited: Duration?
        let service = FeaturedTrailService(store: fake, defaults: defaults(), now: { now }, sleep: { waited = $0 })
        // The load runs on its own; it must finish while the fetch is still
        // held. The outer bound turns a missing deadline into a failure
        // instead of a hang; it waits on the load finishing, not by polling.
        // withDeadline, not a task group: a group waits for every child, so
        // the stuck load would hold it past its bound.
        let load = Task { await service.refreshIfStale() }
        let returned = (try? await OptimisticVote.withDeadline(.seconds(300)) { await load.value; return true }) ?? nil
        #expect(returned == true, "refreshIfStale waited for the held fetch instead of the deadline")
        #expect(waited == .seconds(3))
        #expect(service.list.isEmpty, "this time the list went ahead without it")
        await fake.held()
        fake.gate?.resume()
        await service.fetchInFlight()
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
