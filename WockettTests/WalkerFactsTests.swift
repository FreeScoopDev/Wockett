import Testing
import CloudKit
import CoreLocation
import CryptoKit
import Foundation
import SwiftData
import UIKit
@testable import PoCSquat

/// Walker reports, the app half (spec feat/trail-walker-reports, PR 2): the
/// vocabulary mirrors docs/staff/walker-facts.js, a report holds the trail,
/// the fact and the answer and nothing else, one per person per fact per
/// trail, the questions follow the frequency rules, the trail reaches the
/// summary in memory only, and "Walkers say" reads published summaries only.
@MainActor
struct WalkerFactsTests {

    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private let ref = TrailRef(trailKey: "nc:w123", trailName: "Neuse River Trail", region: "nc",
                               latitude: 35.8, longitude: -78.6, lengthMeters: 4_000)

    // MARK: Vocabulary: the same as docs/staff/walker-facts.js

    private struct JSFact: Equatable {
        let key: String
        let label: String
        let publish: Bool
        let values: [(key: String, label: String)]
        static func == (a: JSFact, b: JSFact) -> Bool {
            a.key == b.key && a.label == b.label && a.publish == b.publish
                && a.values.map(\.key) == b.values.map(\.key) && a.values.map(\.label) == b.values.map(\.label)
        }
    }

    /// Reads walker-facts.js line by line: each fact is a 2-space-indented
    /// key, its label and publish flag, and its values 6 spaces in.
    private func vocabularyFromJS() throws -> [JSFact] {
        let text = try String(contentsOf: repo.appendingPathComponent("docs/staff/walker-facts.js"), encoding: .utf8)
        var facts: [JSFact] = []
        var key: String?, label: String?, publish: Bool?, values: [(String, String)] = []
        func flush() {
            if let key, let label, let publish { facts.append(JSFact(key: key, label: label, publish: publish, values: values)) }
            key = nil; label = nil; publish = nil; values = []
        }
        // Strict: inside WALKER_FACTS every line must be one this parser
        // understands, so a value or fact written another way is an issue,
        // never silently skipped.
        let body = try #require(text.range(of: "export const WALKER_FACTS = Object.freeze({\n"))
        let close = try #require(text.range(of: "\n});", range: body.upperBound..<text.endIndex))
        let structural: Set<String> = ["    values: Object.freeze({", "    }),", "  }),"]
        for line in text[body.upperBound..<close.lowerBound].components(separatedBy: "\n") {
            if structural.contains(line) { continue }
            if let m = line.firstMatch(of: /^  (\w+): Object\.freeze\(\{$/) {
                flush(); key = String(m.1)
            } else if let m = line.firstMatch(of: /^    label: '([^']*)',$/) {
                label = String(m.1)
            } else if let m = line.firstMatch(of: /^    publish: (true|false),$/) {
                publish = m.1 == "true"
            } else if let m = line.firstMatch(of: /^      (\w+): '([^']*)',$/) {
                values.append((String(m.1), String(m.2)))
            } else {
                Issue.record("walker-facts.js line the test can't read: \(line)")
            }
        }
        flush()
        return facts
    }

    private var vocabularyInSwift: [JSFact] {
        WalkerFact.allCases.map { fact in
            JSFact(key: fact.rawValue, label: fact.label, publish: fact.publishes,
                   values: fact.values.map { ($0, fact.valueLabel($0) ?? "?") })
        }
    }

    @Test("The vocabulary is exactly docs/staff/walker-facts.js: facts, values, labels, order and what is published")
    func vocabularyMirrorsDashboard() throws {
        let js = try vocabularyFromJS()
        #expect(js.count == 5, "the parser found every fact")
        #expect(js.map(\.key) == ["dogs", "stroller", "wheelchair", "surface", "liked"])
        #expect(js == vocabularyInSwift)
    }

    @Test("Hard-coded too, so a change to both files at once is still a decision")
    func vocabularyPinned() {
        #expect(WalkerFact.dogs.values == ["leashRequired", "offLeashOK", "noDogs"])
        #expect(WalkerFact.stroller.values == ["yes", "no"])
        #expect(WalkerFact.wheelchair.values == ["yes", "no"])
        #expect(WalkerFact.surface.values == ["paved", "packedDirt", "rockyOrRooty"])
        #expect(WalkerFact.liked.values == ["up", "down"])
        #expect(WalkerFact.allCases.filter { !$0.publishes } == [.liked])
    }

    @Test("Values are case-sensitive and belong to their own fact")
    func valuesAreExact() {
        #expect(WalkerFact.dogs.knows("leashRequired"))
        #expect(!WalkerFact.dogs.knows("LeashRequired"))
        #expect(!WalkerFact.dogs.knows("yes"))
        #expect(!WalkerFact.surface.knows("mud"), "transient conditions are not reportable")
        #expect(WalkerFact.dogs.valueLabel("yes") == nil)
    }

    @Test("The app's walker threshold is the dashboard's MIN_AGREEING")
    func thresholdMirrorsDashboard() throws {
        let logic = try String(contentsOf: repo.appendingPathComponent("docs/staff/logic.js"), encoding: .utf8)
        let match = try #require(logic.firstMatch(of: /export const MIN_AGREEING = (\d+);/))
        #expect(Int(match.1) == TrailFactSummaries.minimumWalkers)
    }

    @Test("Every new icon resolves to a real SF Symbol")
    func symbolsExist() {
        for symbol in [WktSymbol.stroller, .copy, .pets, .wheelchair, .trailSurface] {
            #expect(UIImage(systemName: symbol.name) != nil, "\(symbol.name)")
        }
    }

    // MARK: Reports

    private func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("A report's name is random: nobody can compute it from public ids to test whether someone reported a trail")
    func recordName() throws {
        let a = try #require(TrailFactReports.record(trail: ref, fact: .dogs, value: "noDogs"))
        let b = try #require(TrailFactReports.record(trail: ref, fact: .dogs, value: "noDogs"))
        let name = a.recordID.recordName
        #expect(name.wholeMatch(of: /report\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil)
        #expect(name != b.recordID.recordName, "the same person, trail, fact and answer: still a new name")
        #expect(name != "report." + sha("nc:w123\ndogs\n_me"), "not the old guessable hash")
        #expect(!name.contains("nc:w123"), "nothing readable in the name")
    }

    @Test("A report holds trailKey, region, fact and value, and nothing else: no name, no point, no note")
    func recordFields() throws {
        let record = try #require(TrailFactReports.record(trail: ref, fact: .surface, value: "packedDirt"))
        #expect(record.recordType == "TrailFactReport")
        #expect(record.recordID.recordName.hasPrefix("report."))
        #expect(record.allKeys().sorted() == ["fact", "region", "trailKey", "value"])
        #expect(record["trailKey"] as? String == "nc:w123")
        #expect(record["region"] as? String == "nc")
        #expect(record["fact"] as? String == "surface")
        #expect(record["value"] as? String == "packedDirt")
    }

    @Test("No record for an answer outside the vocabulary")
    func recordRefusesUnknownValues() {
        #expect(TrailFactReports.record(trail: ref, fact: .dogs, value: "maybe") == nil)
        #expect(TrailFactReports.record(trail: ref, fact: .stroller, value: "Yes") == nil)
        let keyless = TrailRef(trailKey: "", trailName: "X", region: "nc", latitude: 0, longitude: 0, lengthMeters: 0)
        #expect(TrailFactReports.record(trail: keyless, fact: .dogs, value: "noDogs") == nil)
    }

    @Test("The schema's TrailFactReport has exactly the fields the app writes")
    func schemaMatchesRecord() throws {
        let schema = try String(contentsOf: repo.appendingPathComponent("cloudkit/schema.ckdb"), encoding: .utf8)
        let start = try #require(schema.range(of: "RECORD TYPE TrailFactReport ("))
        let end = try #require(schema.range(of: ");", range: start.upperBound..<schema.endIndex))
        let fields = schema[start.upperBound..<end.lowerBound].components(separatedBy: "\n")
            .compactMap { $0.firstMatch(of: /^\s+"?([a-zA-Z]\w*)"?\s+[A-Z]/).map { String($0.1) } }
            .filter { $0 != "GRANT" }
        #expect(fields.sorted() == ["fact", "region", "trailKey", "value"])
    }

    private final class FakeReports: TrailFactReportStore {
        var me: String? = "_me"
        var saved: [CKRecord] = []
        var error: Error?
        var hangs = false
        func currentUserRecordName() async throws -> String {
            guard let me else { throw CKError(.notAuthenticated) }
            return me
        }
        func save(_ record: CKRecord) async throws {
            if hangs { try await Task.sleep(for: .seconds(86_400)) }
            if let error { throw error }
            saved.append(record)
        }
    }

    private static let neverFires: OptimisticVote.Sleep = { _ in try await Task.sleep(for: .seconds(86_400)) }
    private static let firesNow: OptimisticVote.Sleep = { _ in }

    @Test("Sending saves one report record")
    func submitSends() async {
        let store = FakeReports()
        let outcome = await TrailFactReportSubmission.submit(ref, fact: .dogs, value: "noDogs", store: store,
                                                             canPost: {}, knownReporter: { nil }, sleep: Self.neverFires)
        #expect(outcome == .sent)
        #expect(store.saved.count == 1)
        #expect(store.saved.first?.recordType == "TrailFactReport")
        #expect(store.saved.first?["value"] as? String == "noDogs")
    }

    @Test("The app's own check asks for the Terms: a report is community content")
    func needsTerms() {
        #expect(TrailFactReportSubmission.needsTerms)
    }

    @Test("A suspended account, or one that skipped the Terms, sends nothing")
    func submitRefusedByAccess() async {
        for error in [CommunityAccessError.suspended(until: nil), .termsNotAgreed] {
            let store = FakeReports()
            let outcome = await TrailFactReportSubmission.submit(ref, fact: .dogs, value: "noDogs", store: store,
                                                                 canPost: { throw error }, knownReporter: { nil },
                                                                 sleep: Self.neverFires)
            #expect(outcome == .failed(error.message))
            #expect(store.saved.isEmpty)
        }
    }

    @Test("Signed out of iCloud: no record, and the message says to sign in")
    func submitNeedsAnAccount() async {
        let store = FakeReports()
        store.me = nil
        let outcome = await TrailFactReportSubmission.submit(ref, fact: .dogs, value: "noDogs", store: store,
                                                             canPost: {}, knownReporter: { nil }, sleep: Self.neverFires)
        #expect(outcome == .failed("Sign in to iCloud in the Settings app to answer."))
        let cached = FakeReports()
        cached.me = nil
        #expect(await TrailFactReportSubmission.submit(ref, fact: .dogs, value: "noDogs", store: cached, canPost: {},
                                                       knownReporter: { "_cached" }, sleep: Self.neverFires) == .sent,
                "the account this phone already knows is enough")
        #expect(store.saved.isEmpty, "the dashboard counts each creator once: no anonymous reports")
    }

    @Test("A second answer to the same question is 'already answered'; a slow save gives up at the deadline")
    func submitOutcomes() async {
        let refused = FakeReports()
        refused.error = CKError(.serverRecordChanged)
        #expect(await TrailFactReportSubmission.submit(ref, fact: .dogs, value: "noDogs", store: refused, canPost: {},
                                                       knownReporter: { nil }, sleep: Self.neverFires) == .alreadyAnswered)
        let slow = FakeReports()
        slow.hangs = true
        #expect(await TrailFactReportSubmission.submit(ref, fact: .dogs, value: "noDogs", store: slow, canPost: {},
                                                       knownReporter: { nil }, sleep: Self.firesNow)
                == .failed("Couldn't send your answer. Check your connection and try again."))
        #expect(TrailFactReportSubmission.deadline == .seconds(15))
        #expect(TrailFactReports.outcome(of: CKError(.notAuthenticated)) == .failed(TrailFactReports.signInMessage))
        #expect(TrailFactReports.outcome(of: CKError(.networkUnavailable)) == .failed(TrailFactReports.failedMessage))
    }

    @Test("A Debug build saves only once the type exists in the container (so it can't create it world-readable)")
    func debugSchemaGuard() {
        #expect(TrailFactReports.debugSaveAllowed(probeError: nil))
        #expect(TrailFactReports.debugSaveAllowed(probeError: CKError(.permissionFailure)))
        #expect(!TrailFactReports.debugSaveAllowed(probeError: CKError(.unknownItem)), "did not find record type")
        #expect(!TrailFactReports.debugSaveAllowed(probeError: CKError(.invalidArguments)), "trailKey not queryable")
        #expect(!TrailFactReports.debugSaveAllowed(probeError: CKError(.networkUnavailable)))
        #expect(TrailFactReports.outcome(of: TrailFactReportSchemaMissing()) == .failed(TrailFactReports.schemaMissingMessage))
    }

    @Test("A Debug save probes first, saves nothing when refused, and probes only until one passes")
    func guardedSaveOrder() async throws {
        var calls: [String] = []
        // Refused: "did not find record type".
        await #expect(throws: TrailFactReportSchemaMissing.self) {
            _ = try await TrailFactReports.guardedSave(checked: false, probe: { calls.append("probe"); throw CKError(.unknownItem) },
                                                       save: { calls.append("save") })
        }
        #expect(calls == ["probe"], "nothing saved")
        // A network failure is the network's message, still nothing saved.
        calls = []
        await #expect(throws: CKError.self) {
            _ = try await TrailFactReports.guardedSave(checked: false, probe: { calls.append("probe"); throw CKError(.networkUnavailable) },
                                                       save: { calls.append("save") })
        }
        #expect(calls == ["probe"])
        // Allowed: probe, then save; and a passed probe is not repeated.
        calls = []
        let checked = try await TrailFactReports.guardedSave(checked: false, probe: { calls.append("probe") },
                                                             save: { calls.append("save") })
        #expect(checked)
        _ = try await TrailFactReports.guardedSave(checked: checked, probe: { calls.append("probe") },
                                                   save: { calls.append("save") })
        #expect(calls == ["probe", "save", "save"])
    }

    @Test("Under unit tests the app's report store can't reach CloudKit")
    func testsNeverReachCloudKit() {
        #expect(TrailFactReportSubmission.defaultStore() is NoTrailFactReportStore)
    }

    // MARK: When to ask (injected clock)

    private final class Clock {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
    }

    private func policy(_ clock: Clock) throws -> TrailReportAskPolicy {
        let suite = "wkt.tests.trailReports.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return TrailReportAskPolicy(defaults: defaults, now: { clock.now })
    }

    private func walk(_ meters: Double = 3_000, activity: ActivityMode = .walking, hike: Bool = false) -> WalkSession {
        WalkSession(id: UUID(), routeName: "Neuse River Trail", date: Date(), elapsedTime: 1_800,
                    totalDistance: meters, waypoints: [], lapCount: 1, isLoop: false,
                    activityType: activity.rawValue, isHike: hike)
    }

    private func trail(_ key: String) -> TrailRef {
        TrailRef(trailKey: key, trailName: "Trail \(key)", region: "nc", latitude: 35.8, longitude: -78.6, lengthMeters: 2_000)
    }

    @Test("Asked on the summary of a finished walk or hike on a named trail")
    func asksAfterATrailWalk() throws {
        let p = try policy(Clock())
        #expect(p.shouldAsk(trail: ref, session: walk(), justFinished: true, walkInProgress: false))
        #expect(p.shouldAsk(trail: ref, session: walk(hike: true), justFinished: true, walkInProgress: false))
    }

    @Test("Never off a trail, from history, mid-walk, on a run or ride, or for a walk too short to know the trail")
    func neverAsksOtherwise() throws {
        let p = try policy(Clock())
        #expect(!p.shouldAsk(trail: nil, session: walk(), justFinished: true, walkInProgress: false))
        #expect(!p.shouldAsk(trail: ref, session: walk(), justFinished: false, walkInProgress: false))
        #expect(!p.shouldAsk(trail: ref, session: walk(), justFinished: true, walkInProgress: true))
        #expect(!p.shouldAsk(trail: ref, session: walk(activity: .running), justFinished: true, walkInProgress: false))
        #expect(!p.shouldAsk(trail: ref, session: walk(activity: .cycling), justFinished: true, walkInProgress: false))
        #expect(!p.shouldAsk(trail: ref, session: walk(activity: .stationary), justFinished: true, walkInProgress: false))
        #expect(!p.shouldAsk(trail: ref, session: walk(399), justFinished: true, walkInProgress: false))
        #expect(p.shouldAsk(trail: ref, session: walk(400), justFinished: true, walkInProgress: false))
    }

    @Test("At most one ask per trail, ever, even weeks later")
    func onePerTrail() throws {
        let clock = Clock()
        let p = try policy(clock)
        p.noteAsked(ref)
        clock.now += 60 * 24 * 3_600
        #expect(!p.shouldAsk(trail: ref, session: walk(), justFinished: true, walkInProgress: false))
        #expect(p.shouldAsk(trail: trail("nc:w9"), session: walk(), justFinished: true, walkInProgress: false))
    }

    @Test("At most one ask a week overall: another trail waits 7 days to the second")
    func onePerWeek() throws {
        let clock = Clock()
        let p = try policy(clock)
        p.noteAsked(ref)
        let other = trail("nc:w9")
        #expect(!p.shouldAsk(trail: other, session: walk(), justFinished: true, walkInProgress: false))
        clock.now += 7 * 24 * 3_600 - 1
        #expect(!p.shouldAsk(trail: other, session: walk(), justFinished: true, walkInProgress: false))
        clock.now += 1
        #expect(p.shouldAsk(trail: other, session: walk(), justFinished: true, walkInProgress: false))
    }

    @Test("Never for a trail already answered, even if this phone never recorded the ask")
    func neverForAnAnsweredTrail() throws {
        let p = try policy(Clock())
        p.noteAnswered(ref)
        #expect(!p.shouldAsk(trail: ref, session: walk(), justFinished: true, walkInProgress: false))
        #expect(p.shouldAsk(trail: trail("nc:w9"), session: walk(), justFinished: true, walkInProgress: false))
    }

    @Test("Never after Don't ask again, until the Settings switch turns it back on")
    func dontAskAgain() throws {
        let p = try policy(Clock())
        p.asksOff = true
        #expect(!p.shouldAsk(trail: ref, session: walk(), justFinished: true, walkInProgress: false))
        #expect(p.defaults.bool(forKey: "wkt_trailReports_off"), "the key the Settings switch stores")
        p.asksOff = false
        #expect(p.shouldAsk(trail: ref, session: walk(), justFinished: true, walkInProgress: false))
    }

    @Test("The thank-you is for the first answer ever, once")
    func firstAnswerThanks() throws {
        let p = try policy(Clock())
        #expect(p.noteAnswered(ref))
        #expect(!p.noteAnswered(trail("nc:w9")))
        #expect(!p.noteAnswered(ref))
    }

    @Test("The remembered trails are capped, newest kept")
    func rememberedListIsCapped() throws {
        let p = try policy(Clock())
        for i in 0...TrailReportAskPolicy.rememberedTrails { p.noteAsked(trail("nc:w\(i)")) }
        #expect(!p.hasAsked("nc:w0"))
        #expect(p.hasAsked("nc:w1"))
        #expect(p.hasAsked("nc:w\(TrailReportAskPolicy.rememberedTrails)"))
    }

    // MARK: Never mid-walk: the store's own signal

    private func inMemoryHistory() throws -> WalkHistoryStore {
        let config = ModelConfiguration(schema: AppModelContainer.schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppModelContainer.schema, configurations: config)
        return WalkHistoryStore(context: ModelContext(container))
    }

    private func trailRoute(trail: TrailRef?) -> NavigableRoute {
        NavigableRoute(name: "Neuse River Trail",
                       waypoints: [CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64),
                                   CLLocationCoordinate2D(latitude: 35.79, longitude: -78.64)],
                       lapCount: 1, isLoop: false, totalDistance: 1_500, activityMode: .walking, trail: trail)
    }

    @Test("A walk is in progress until it ends; the summary's stopped session is not one")
    func walkInProgressSignal() throws {
        let store = ActiveWalkStore(historyStore: try inMemoryHistory())
        #expect(!store.isWalkInProgress)
        let mgr = try #require(store.beginSession(route: trailRoute(trail: ref)))
        mgr.writesSnapshots = false
        #expect(store.isWalkInProgress)
        let p = try policy(Clock())
        #expect(!p.shouldAsk(trail: ref, session: walk(), justFinished: true, walkInProgress: store.isWalkInProgress))
        store.end(.save, releaseSession: false)
        #expect(store.session != nil, "still held for the summary")
        #expect(!store.isWalkInProgress)
        #expect(p.shouldAsk(trail: ref, session: walk(), justFinished: true, walkInProgress: store.isWalkInProgress))
    }

    // MARK: The trail reaches the summary in memory only

    @Test("A walk ended on the walk screen hands its trail to the summary; the next session starts clean")
    func endedTrailForTheWalkScreen() throws {
        let store = ActiveWalkStore(historyStore: try inMemoryHistory())
        let mgr = try #require(store.beginSession(route: trailRoute(trail: ref)))
        mgr.writesSnapshots = false
        #expect(store.endedTrail == nil)
        store.end(.save, releaseSession: false)
        #expect(store.endedTrail == ref)
        store.endSession()
        #expect(store.endedTrail == nil)
        let discarded = try #require(store.beginSession(route: trailRoute(trail: ref)))
        discarded.writesSnapshots = false
        store.end(.discard, releaseSession: false)
        #expect(store.endedTrail == nil, "a discarded walk has no summary to ask on")
    }

    @Test("A walk ended away from the walk screen hands its trail to the summary")
    func pendingSummaryCarriesTheTrail() throws {
        let store = ActiveWalkStore(historyStore: try inMemoryHistory())
        let mgr = try #require(store.beginSession(route: trailRoute(trail: ref)))
        mgr.writesSnapshots = false
        mgr.totalDistanceCovered = 1_000
        store.end(.save, presentSummary: true)
        #expect(store.pendingSummary?.trail == ref)

        let plain = ActiveWalkStore(historyStore: try inMemoryHistory())
        let other = try #require(plain.beginSession(route: trailRoute(trail: nil)))
        other.writesSnapshots = false
        plain.end(.save, presentSummary: true)
        #expect(plain.pendingSummary != nil)
        #expect(plain.pendingSummary?.trail == nil)
    }

    @Test("The crash checkpoint never holds the trail, so a restored walk asks nothing")
    func checkpointHasNoTrail() throws {
        let route = trailRoute(trail: ref)
        #expect(route.trail == ref)
        let data = try JSONEncoder().encode(ActiveWalkSnapshot.RouteData(route))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("nc:w123") && !text.contains("trailKey"))
        let restored = try JSONDecoder().decode(ActiveWalkSnapshot.RouteData.self, from: data).navigableRoute
        #expect(restored.trail == nil)
    }

    // Fixture: a keyed trail ~1 km east from (35.78, -78.64).
    private func encode(_ coords: [CLLocationCoordinate2D]) -> String {
        var out = ""
        var lastLat = 0, lastLon = 0
        for c in coords {
            let lat = Int((c.latitude * 1e5).rounded()), lon = Int((c.longitude * 1e5).rounded())
            for delta in [lat - lastLat, lon - lastLon] {
                var v = delta < 0 ? ~(delta << 1) : (delta << 1)
                while v >= 0x20 {
                    out.append(Character(UnicodeScalar(UInt8((0x20 | (v & 0x1f)) + 63))))
                    v >>= 5
                }
                out.append(Character(UnicodeScalar(UInt8(v + 63))))
            }
            lastLat = lat; lastLon = lon
        }
        return out
    }

    private var line: [CLLocationCoordinate2D] {
        (0..<11).map { CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64 + Double($0) * 0.0011) }
    }

    private var keyedItem: TrailListItem {
        let coords = line
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let feature = TrailFeature(id: 1, sourceID: "osm", sourceRef: "w1", name: "Test Greenway",
                                   encodedPolyline: encode(coords), pointCount: coords.count,
                                   lengthMeters: TrailWalkPlanner.length(coords),
                                   bounds: TrailBounds(minLatitude: lats.min() ?? 0, minLongitude: lons.min() ?? 0,
                                                       maxLatitude: lats.max() ?? 0, maxLongitude: lons.max() ?? 0),
                                   surface: nil, difficulty: nil, dogAccess: .unknown, dogAccessProvenance: .default,
                                   allowsFoot: true, allowsBike: true, allowsHorse: false, isLoop: false,
                                   trailKey: "nc:w1")
        return TrailListItem(id: "osm:w1", name: "Test Greenway", sections: [feature], distanceMeters: 900)
    }

    @Test("A trail reached from the way there becomes the session's trail on arrival, not before")
    func arrivalSetsTheTrail() throws {
        let approach = TrailApproach(item: keyedItem)
        let home = CLLocationCoordinate2D(latitude: 35.7881, longitude: -78.6345)
        let access = CLLocationCoordinate2D(latitude: 35.78, longitude: -78.6345)
        let mgr = NavigationSessionManager(route: approach.navigableRoute(from: home, to: access,
                                                                          distanceMeters: 1_100, activityMode: .walking))
        mgr.writesSnapshots = false
        #expect(mgr.route.trail == nil, "the way there is not the trail")
        mgr.checkArrival(at: CLLocation(coordinate: access, altitude: 0, horizontalAccuracy: 5,
                                        verticalAccuracy: 5, timestamp: Date()))
        let next = try #require(mgr.beginTrailWalk())
        #expect(next.trail?.trailKey == "nc:w1")
        #expect(mgr.route.trail?.trailKey == "nc:w1")
    }

    @Test("A walk restored on the way to a trail learns its trail on arrival, after the restart: it was walked then")
    func restoredApproachGetsTrailOnArrival() throws {
        let approach = TrailApproach(item: keyedItem)
        let home = CLLocationCoordinate2D(latitude: 35.7881, longitude: -78.6345)
        let access = CLLocationCoordinate2D(latitude: 35.78, longitude: -78.6345)
        let route = approach.navigableRoute(from: home, to: access, distanceMeters: 1_100, activityMode: .walking)
        let data = try JSONEncoder().encode(ActiveWalkSnapshot.RouteData(route))
        let restored = try JSONDecoder().decode(ActiveWalkSnapshot.RouteData.self, from: data).navigableRoute
        #expect(restored.trail == nil)
        let mgr = NavigationSessionManager(route: restored)
        mgr.writesSnapshots = false
        mgr.checkArrival(at: CLLocation(coordinate: access, altitude: 0, horizontalAccuracy: 5,
                                        verticalAccuracy: 5, timestamp: Date()))
        #expect(try #require(mgr.beginTrailWalk()).trail?.trailKey == "nc:w1")
    }

    @Test("Head back now, a recording's line and turning round all keep the trail")
    func routeCopiesKeepTheTrail() throws {
        let planned = try #require(TrailWalkPlanner.plan(for: keyedItem, from: line[0], target: .roundTrip(meters: 800)))
        #expect(planned.trail == nil, "the planner leaves it to whoever starts the walk")
        let plan = planned.started(from: keyedItem)
        #expect(plan.trail == TrailRef(item: keyedItem), "the detail's Start carries the trail")
        #expect(plan == planned, "and changes nothing else about the walk")
        let route = plan.navigableRoute(activityMode: .walking)
        #expect(route.trail?.trailKey == "nc:w1")
        #expect(route.followingRecordedLine().trail?.trailKey == "nc:w1")
        #expect(try #require(route.reversedAlongLine()).trail?.trailKey == "nc:w1")
        let mgr = NavigationSessionManager(route: route)
        mgr.writesSnapshots = false
        mgr.applySnapshot(ActiveWalkSnapshot(route: .init(route), startTime: Date().addingTimeInterval(-600),
                                             totalDistanceCovered: 300, pausedDuration: 0, isPaused: false,
                                             pauseStartDate: nil, currentWaypointIndex: 1, currentLap: 1,
                                             triggeredCheckpoints: [], splitTimes: [], liveSteps: 0,
                                             checkpointDate: Date(), trailAlong: 300))
        let back = try #require(mgr.headBack())
        #expect(back.trail?.trailKey == "nc:w1")
    }

    // MARK: The card

    private func cardModel(_ p: TrailReportAskPolicy,
                           outcome: @escaping (WalkerFact, String) -> TrailFactReports.Outcome = { _, _ in .sent })
        -> (TrailReportCardModel, () -> [String]) {
        var sent: [String] = []
        let model = TrailReportCardModel(trail: ref, policy: p) { fact, value in
            sent.append("\(fact.rawValue)=\(value)")
            return outcome(fact, value)
        }
        return (model, { sent })
    }

    @Test("The summary's card is decided without spending the ask; the ask is spent once, when the card is seen or used")
    func askSpentWhenSeen() async throws {
        let clock = Clock()
        let p = try policy(clock)
        let idle = ActiveWalkStore(historyStore: try inMemoryHistory())
        #expect(TrailReportCardModel.forSummary(trail: ref, session: walk(), moment: .history, walkStore: idle, policy: p) == nil)
        let walking = ActiveWalkStore(historyStore: try inMemoryHistory())
        let mgr = try #require(walking.beginSession(route: trailRoute(trail: ref)))
        mgr.writesSnapshots = false
        #expect(TrailReportCardModel.forSummary(trail: ref, session: walk(), moment: .justFinished, walkStore: walking,
                                                policy: p) == nil, "never while a walk is recorded")
        let model = try #require(TrailReportCardModel.forSummary(trail: ref, session: walk(), moment: .justFinished,
                                                                 walkStore: idle, policy: p))
        #expect(!p.hasAsked("nc:w123"), "a card never scrolled to costs nothing")
        #expect(p.defaults.object(forKey: TrailReportAskPolicy.lastAskKey) == nil)
        model.markShown()
        #expect(p.hasAsked("nc:w123"))
        let first = p.defaults.object(forKey: TrailReportAskPolicy.lastAskKey) as? Date
        clock.now += 60
        model.markShown()
        #expect(p.defaults.object(forKey: TrailReportAskPolicy.lastAskKey) as? Date == first, "once")

        let other = try policy(Clock())
        let (used, _) = cardModel(other)
        await used.answer(.dogs, "noDogs")
        #expect(other.hasAsked("nc:w123"), "answering means it was seen")
        let closedPolicy = try policy(Clock())
        let (closed, _) = cardModel(closedPolicy)
        closed.close()
        let stoppedPolicy = try policy(Clock())
        let (stopped, _) = cardModel(stoppedPolicy)
        stopped.stopAsking()
        for m in [closed, stopped] { #expect(m.asking == false) }
        #expect(closedPolicy.hasAsked("nc:w123"), "Not now / Skip means it was seen")
        #expect(stoppedPolicy.hasAsked("nc:w123"), "Don't ask again means it was seen")
    }

    @Test("An answer CloudKit already had doesn't use up the first-answer thank-you")
    func alreadyAnsweredKeepsThanks() async throws {
        let p = try policy(Clock())
        let (again, _) = cardModel(p) { _, _ in .alreadyAnswered }
        await again.answer(.dogs, "noDogs")
        #expect(!again.showThanks)
        #expect(p.hasAnswered("nc:w123"))
        #expect(p.noteAnswered(trail("nc:w9")), "the first real answer is still thanked")
    }

    @Test("Every question is offered, liked included; one tap sends one answer, and it can't be changed")
    func cardOneTapEach() async throws {
        let (model, sent) = cardModel(try policy(Clock()))
        #expect(model.facts == [.dogs, .stroller, .wheelchair, .surface, .liked])
        #expect(!model.hasAnswered)
        await model.answer(.dogs, "leashRequired")
        await model.answer(.dogs, "noDogs")
        #expect(sent() == ["dogs=leashRequired"])
        #expect(model.selected(.dogs) == "leashRequired")
        #expect(!model.canAnswer(.dogs))
        #expect(model.canAnswer(.surface), "each question is separate and optional")
        #expect(model.hasAnswered)
    }

    @Test("A question can't be answered twice while its first answer is still sending")
    func cardNoDoubleSend() async throws {
        var sent = 0
        var release: CheckedContinuation<Void, Never>?
        let model = TrailReportCardModel(trail: ref, policy: try policy(Clock())) { _, _ in
            sent += 1
            await withCheckedContinuation { release = $0 }
            return .sent
        }
        let first = Task { await model.answer(.dogs, "noDogs") }
        while release == nil { await Task.yield() }
        await model.answer(.dogs, "leashRequired")
        #expect(sent == 1)
        #expect(!model.canAnswer(.dogs))
        release?.resume()
        await first.value
        #expect(model.selected(.dogs) == "noDogs")
    }

    @Test("An answer outside the vocabulary is never sent")
    func cardRefusesUnknownValues() async throws {
        let (model, sent) = cardModel(try policy(Clock()))
        await model.answer(.dogs, "yes")
        #expect(sent().isEmpty)
        #expect(model.canAnswer(.dogs))
    }

    @Test("A failed send can be tried again; a refused second answer counts as answered")
    func cardFailures() async throws {
        var fail = true
        let (model, sent) = cardModel(try policy(Clock())) { _, _ in fail ? .failed("Nope") : .sent }
        await model.answer(.surface, "paved")
        #expect(model.error(for: .surface) == "Nope")
        #expect(model.canAnswer(.surface))
        fail = false
        await model.answer(.surface, "paved")
        #expect(sent() == ["surface=paved", "surface=paved"])
        #expect(model.selected(.surface) == "paved")

        let (again, _) = cardModel(try policy(Clock())) { _, _ in .alreadyAnswered }
        await again.answer(.stroller, "yes")
        #expect(!again.canAnswer(.stroller))
        #expect(again.hasAnswered)
    }

    @Test("The first answer ever shows the thank-you; later cards don't")
    func cardThanksOnce() async throws {
        let p = try policy(Clock())
        let (first, _) = cardModel(p)
        #expect(!first.showThanks)
        await first.answer(.dogs, "noDogs")
        #expect(first.showThanks)
        let (second, _) = cardModel(p)
        await second.answer(.dogs, "noDogs")
        #expect(!second.showThanks)
    }

    @Test("Answering marks the trail answered; Skip and Not now close the card; Don't ask again turns asks off")
    func cardClosing() async throws {
        let p = try policy(Clock())
        let (model, sent) = cardModel(p)
        await model.answer(.liked, "up")
        #expect(p.hasAnswered("nc:w123"))
        model.close()
        #expect(!model.asking)
        await model.answer(.dogs, "noDogs")
        #expect(sent() == ["liked=up"], "nothing is sent after the card closes")
        #expect(!p.asksOff)

        let (other, _) = cardModel(p)
        other.stopAsking()
        #expect(!other.asking)
        #expect(p.asksOff)
    }

    @Test("Once every question is answered the card stops asking")
    func cardCompletes() async throws {
        let (model, _) = cardModel(try policy(Clock()))
        for fact in WalkerFact.allCases {
            #expect(model.asking)
            await model.answer(fact, fact.values[0])
        }
        #expect(model.isComplete)
        #expect(!model.asking)
    }

    // MARK: Summaries: tolerant decode

    private func summaryRecord(key: Any? = "nc:w123", fact: Any? = "dogs", value: Any? = "leashRequired",
                               walkers: Any? = 4 as Int64, type: String = "TrailFactSummary") -> CKRecord {
        let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: "factsummary.dogs.nc.w123"))
        if let key = key as? CKRecordValue { record["trailKey"] = key }
        if let fact = fact as? CKRecordValue { record["fact"] = fact }
        if let value = value as? CKRecordValue { record["value"] = value }
        if let walkers = walkers as? CKRecordValue { record["walkers"] = walkers }
        record["computedAt"] = Date(timeIntervalSince1970: 1_000)
        return record
    }

    @Test("A published summary decodes")
    func summaryDecodes() throws {
        let s = try #require(TrailFactSummaries.summary(from: summaryRecord()))
        #expect(s == WalkerFactSummary(trailKey: "nc:w123", fact: .dogs, value: "leashRequired", walkers: 4,
                                       computedAt: Date(timeIntervalSince1970: 1_000)))
    }

    @Test("Unknown or unpublished facts, unknown values and malformed records are skipped, not guessed")
    func summaryTolerance() {
        #expect(TrailFactSummaries.summary(from: summaryRecord(fact: "shade")) == nil, "a fact this version doesn't know")
        #expect(TrailFactSummaries.summary(from: summaryRecord(fact: "liked", value: "up")) == nil, "never shown")
        #expect(TrailFactSummaries.summary(from: summaryRecord(value: "muzzled")) == nil, "a value this version doesn't know")
        #expect(TrailFactSummaries.summary(from: summaryRecord(value: "yes")) == nil, "another fact's value")
        #expect(TrailFactSummaries.summary(from: summaryRecord(key: "")) == nil)
        #expect(TrailFactSummaries.summary(from: summaryRecord(key: nil)) == nil)
        #expect(TrailFactSummaries.summary(from: summaryRecord(walkers: nil)) == nil)
        #expect(TrailFactSummaries.summary(from: summaryRecord(walkers: "4")) == nil)
        #expect(TrailFactSummaries.summary(from: summaryRecord(walkers: 4.5)) == nil)
        #expect(TrailFactSummaries.summary(from: summaryRecord(walkers: 2 as Int64)) == nil, "under the rule")
        #expect(TrailFactSummaries.summary(from: summaryRecord(walkers: 3 as Int64)) != nil)
        #expect(TrailFactSummaries.summary(from: summaryRecord(type: "TrailFactReport")) == nil, "never a report")
    }

    // MARK: Walkers say lines

    private func summary(_ key: String, _ fact: WalkerFact, _ value: String, _ walkers: Int, at t: TimeInterval = 0)
        -> WalkerFactSummary {
        WalkerFactSummary(trailKey: key, fact: fact, value: value, walkers: walkers, computedAt: Date(timeIntervalSince1970: t))
    }

    @Test("One line per published fact, worded from the vocabulary: 'Dogs on leash (4 walkers)'")
    func lines() {
        let lines = TrailFactSummaries.lines(forKeys: ["nc:w123"], in: [
            summary("nc:w123", .surface, "packedDirt", 5),
            summary("nc:w123", .dogs, "leashRequired", 4),
            summary("nc:w9", .stroller, "yes", 6)
        ])
        #expect(lines.map(\.text) == ["Dogs on leash (4 walkers)", "Packed dirt (5 walkers)"])
        #expect(lines.map(\.fact) == [.dogs, .surface])
    }

    @Test("Never a liked line, an unknown value or a count under the rule, even if one got into the cache")
    func linesFilter() {
        let lines = TrailFactSummaries.lines(forKeys: ["nc:w123"], in: [
            summary("nc:w123", .liked, "up", 9),
            summary("nc:w123", .dogs, "maybe", 9),
            summary("nc:w123", .stroller, "no", 2)
        ])
        #expect(lines.isEmpty)
    }

    @Test("The trail's own key wins; a key's newest summary wins")
    func linesPrecedence() {
        let lines = TrailFactSummaries.lines(forKeys: ["nc:w1", "nc:w2"], in: [
            summary("nc:w2", .dogs, "noDogs", 9),
            summary("nc:w1", .dogs, "leashRequired", 3, at: 10),
            summary("nc:w1", .dogs, "offLeashOK", 4, at: 20),
            summary("nc:w2", .surface, "paved", 3)
        ])
        #expect(lines.map(\.text) == ["Dogs off leash OK (4 walkers)", "Paved (3 walkers)"])
    }

    @Test("A trail's keys come from its sections, its own first, each once")
    func keysOfItem() {
        func section(_ id: Int64, _ key: String?) -> TrailFeature {
            let f = keyedItem.sections[0]
            return TrailFeature(id: id, sourceID: f.sourceID, sourceRef: "w\(id)", name: f.name,
                                encodedPolyline: f.encodedPolyline, pointCount: f.pointCount, lengthMeters: f.lengthMeters,
                                bounds: f.bounds, surface: nil, difficulty: nil, dogAccess: .unknown,
                                dogAccessProvenance: .default, allowsFoot: true, allowsBike: false, allowsHorse: false,
                                isLoop: false, trailKey: key)
        }
        let item = TrailListItem(id: "x", name: "X", sections: [section(1, nil), section(2, "nc:w2"), section(3, "nc:w1"),
                                                                section(4, "nc:w2")], distanceMeters: 0)
        #expect(TrailFactSummaries.keys(of: item) == ["nc:w2", "nc:w1"])
        #expect(TrailRef(item: item)?.trailKey == "nc:w2", "the key a report names is the first")
    }

    // MARK: Summaries: cache and daily refresh

    private final class FakeSummaries: TrailFactSummaryStore {
        var answer: [WalkerFactSummary] = []
        var error: Error?
        var asked: [[String]] = []
        func summaries(forKeys keys: [String]) async throws -> [WalkerFactSummary] {
            asked.append(keys)
            if let error { throw error }
            return answer.filter { keys.contains($0.trailKey) }
        }
    }

    private func defaults() throws -> UserDefaults {
        let suite = "wkt.tests.summaries.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test("Fetched once, then not again for a day; a withdrawn summary goes at the next refresh")
    func dailyRefresh() async throws {
        let clock = Clock()
        let store = FakeSummaries()
        store.answer = [summary("nc:w123", .dogs, "leashRequired", 4)]
        let service = TrailFactSummaryService(store: store, defaults: try defaults(), now: { clock.now })
        await service.refreshIfStale(keys: ["nc:w123"])
        #expect(service.lines(forKeys: ["nc:w123"]).map(\.text) == ["Dogs on leash (4 walkers)"])
        store.answer = []
        clock.now += 86_400 - 1
        await service.refreshIfStale(keys: ["nc:w123"])
        #expect(store.asked.count == 1, "not yet a day")
        #expect(service.lines(forKeys: ["nc:w123"]).count == 1)
        clock.now += 1
        await service.refreshIfStale(keys: ["nc:w123"])
        #expect(store.asked.count == 2)
        #expect(service.lines(forKeys: ["nc:w123"]).isEmpty, "Joe withdrew it")
    }

    @Test("Only the stale keys are fetched")
    func onlyStaleKeys() async throws {
        let clock = Clock()
        let store = FakeSummaries()
        let service = TrailFactSummaryService(store: store, defaults: try defaults(), now: { clock.now })
        await service.refreshIfStale(keys: ["nc:w1"])
        clock.now += 3_600
        await service.refreshIfStale(keys: ["nc:w1", "nc:w2"])
        #expect(store.asked == [["nc:w1"], ["nc:w2"]])
    }

    @Test("Offline: a failed fetch keeps the cache, survives a relaunch, and retries after a pause, not on every open")
    func offlineCache() async throws {
        let clock = Clock()
        let d = try defaults()
        let store = FakeSummaries()
        store.answer = [summary("nc:w123", .surface, "paved", 3)]
        let first = TrailFactSummaryService(store: store, defaults: d, now: { clock.now })
        await first.refreshIfStale(keys: ["nc:w123"])

        clock.now += 2 * 86_400
        store.error = CKError(.networkUnavailable)
        let relaunched = TrailFactSummaryService(store: store, defaults: d, now: { clock.now })
        #expect(relaunched.lines(forKeys: ["nc:w123"]).map(\.text) == ["Paved (3 walkers)"], "from the cache")
        await relaunched.refreshIfStale(keys: ["nc:w123"])
        #expect(store.asked.count == 2)
        #expect(relaunched.lines(forKeys: ["nc:w123"]).map(\.text) == ["Paved (3 walkers)"], "kept on failure")
        await relaunched.refreshIfStale(keys: ["nc:w123"])
        #expect(store.asked.count == 2, "no retry straight away")
        clock.now += TrailFactSummaryService.retryAfterFailure
        await relaunched.refreshIfStale(keys: ["nc:w123"])
        #expect(store.asked.count == 3)
    }

    @Test("A fetch cancelled by closing the detail is not a failure: reopening fetches at once")
    func cancelledFetch() async throws {
        let store = FakeSummaries()
        store.error = CancellationError()
        let service = TrailFactSummaryService(store: store, defaults: try defaults(), now: { Date(timeIntervalSince1970: 0) })
        await service.refreshIfStale(keys: ["nc:w1"])
        #expect(service.staleKeys(["nc:w1"]) == ["nc:w1"])
        store.error = CKError(.operationCancelled)
        await service.refreshIfStale(keys: ["nc:w1"])
        #expect(service.staleKeys(["nc:w1"]) == ["nc:w1"], "CloudKit's own cancellation too")
        store.error = CKError(.networkUnavailable)
        await service.refreshIfStale(keys: ["nc:w1"])
        #expect(service.staleKeys(["nc:w1"]).isEmpty, "a real failure waits")
    }

    @Test("The cache keeps the newest trails only")
    func cacheIsCapped() async throws {
        let clock = Clock()
        let d = try defaults()
        let service = TrailFactSummaryService(store: FakeSummaries(), defaults: d, now: { clock.now })
        for i in 0...TrailFactSummaryService.cachedTrails {
            clock.now += 1
            await service.refreshIfStale(keys: ["nc:w\(i)"])
        }
        #expect(service.entries.count == TrailFactSummaryService.cachedTrails)
        #expect(service.entries["nc:w0"] == nil)
        let reloaded = TrailFactSummaryService(store: FakeSummaries(), defaults: d, now: { clock.now })
        #expect(reloaded.entries.count == TrailFactSummaryService.cachedTrails)
    }

    // MARK: The facts card

    private let mapFact = TrailFacts.Fact(kind: .surface, label: "Surface", text: "Smooth", symbol: .trailSurface)
    private let walkerLine = WalkerFactLine(fact: .dogs, text: "Dogs on leash (4 walkers)")

    @Test("Walkers say sits below the map facts, shows alone when the map says nothing, and nothing shows for neither")
    func cardParts() {
        #expect(TrailFactsCard.parts(facts: [mapFact], walkerLines: [walkerLine]) == [.mapData, .walkers])
        #expect(TrailFactsCard.parts(facts: [], walkerLines: [walkerLine]) == [.walkers])
        #expect(TrailFactsCard.parts(facts: [mapFact], walkerLines: []) == [.mapData])
        #expect(TrailFactsCard.parts(facts: [], walkerLines: []).isEmpty)
    }

    @Test("Walker lines are worded apart from the map data: their own heading and caption")
    func cardWording() {
        #expect(TrailFactsCard.caption(for: .mapData) == TrailFacts.caption)
        #expect(TrailFactsCard.caption(for: .walkers) == TrailFactsCard.walkersCaption)
        #expect(TrailFactsCard.walkersTitle == "Walkers say")
        #expect(TrailFacts.caption == "From the trail's map data, not a current report", "map caption untouched")
        #expect(TrailFactsCard.walkersCaption != TrailFacts.caption)
        #expect(TrailFactsCard.walkersCaption.contains("walkers"))
        #expect(TrailFactsCard.walkersCaption.contains("\(TrailFactSummaries.minimumWalkers)"))
    }

    // MARK: Copy

    @Test("The deletion copy names trail reports and says trail nominations, not trail suggestions")
    func deletionCopy() {
        #expect(CommunityDataDeletion.undeletable.map(\.recordType) == ["CommunityReport", "TrailNomination", "TrailFactReport"])
        #expect(CommunityDataDeletion.undeletable.map(\.title)
                == ["Reports you sent", "Trail nominations you sent", "Trail reports you sent"])
        let note = CommunityDataDeletion.undeletableNote
        #expect(note.contains("trail nominations"))
        #expect(note.contains("trail reports"))
        #expect(!note.lowercased().contains("suggestion"))
    }

    @Test("The removal email carries the identifier on its own line, exactly as iCloud gives it")
    func removalEmail() throws {
        let id = "_0123456789abcdef0123456789abcdef"
        let url = try #require(CommunityDataDeletion.supportMailURL(account: id))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let body = try #require(items.first { $0.name == "body" }?.value)
        #expect(body.components(separatedBy: "\n").contains("My identifier: \(id)"))
        #expect(body.contains("trail reports"))
        // The dashboard's walkerId(): /^_[A-Za-z0-9]{16,128}$/ after trimming.
        let line = try #require(body.components(separatedBy: "\n").first { $0.hasPrefix("My identifier: ") })
        let pasted = String(line.dropFirst("My identifier: ".count))
        #expect(pasted.wholeMatch(of: /_[A-Za-z0-9]{16,128}/) != nil)
    }
}
