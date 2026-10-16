import Testing
import CloudKit
import CryptoKit
import Foundation
import UserNotifications
@testable import PoCSquat

/// My contributions, the app half (spec feat/contribution-status, C2): every
/// nomination carries a fresh random claim token kept on this phone; the
/// phone reads `status.<sha256(token)>` and nothing derivable from public
/// ids; the vocabulary mirrors docs/staff/contribution-status.js; a status
/// it doesn't understand stays Sent; each contribution is announced once
/// on the banner and once by a local notification. Fakes only: nothing
/// here can reach CloudKit.
@MainActor
struct ContributionStatusTests {

    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private let lakeLoop = TrailRef(trailKey: "nc:w9", trailName: "Lake Loop", region: "nc",
                                    latitude: 35.78, longitude: -78.64, lengthMeters: 2_400)

    // MARK: Fixtures

    private final class Clock {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
    }

    private func defaults() throws -> UserDefaults {
        let suite = "wkt.tests.contributions.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// Answers lookups from `records` (by name); a name not in `records` is
    /// `.missing` unless it is in `unanswered`. Counts and records each ask.
    private final class FakeStatuses: ContributionStatusStore {
        var records: [String: CKRecord] = [:]
        var unanswered: Set<String> = []
        var error: Error?
        var asked: [[String]] = []
        func lookup(names: [String]) async throws -> [String: ContributionStatusLookup] {
            asked.append(names.sorted())
            if let error { throw error }
            var out: [String: ContributionStatusLookup] = [:]
            for name in names where !unanswered.contains(name) {
                out[name] = records[name].map { .found($0) } ?? .missing
            }
            return out
        }
    }

    private final class FakeNominations: TrailNominationStore {
        var saved: [CKRecord] = []
        var error: Error?
        var hangs = false
        func save(_ record: CKRecord) async throws {
            if hangs { try await Task.sleep(for: .seconds(86_400)) }
            if let error { throw error }
            saved.append(record)
        }
    }

    private static let neverFires: OptimisticVote.Sleep = { _ in try await Task.sleep(for: .seconds(86_400)) }

    private func statusRecord(token: String, kind: Any? = "nomination", status: Any? = "featured",
                              trailKey: Any? = "nc:w9", type: String = "ContributionStatus",
                              name: String? = nil) -> CKRecord {
        let record = CKRecord(recordType: type,
                              recordID: CKRecord.ID(recordName: name ?? ContributionStatuses.recordName(claimToken: token)))
        record["kind"] = kind as? CKRecordValue
        record["status"] = status as? CKRecordValue
        record["trailKey"] = trailKey as? CKRecordValue
        record["trailName"] = "Lake Loop (as featured)"
        record["decidedAt"] = Date(timeIntervalSince1970: 1_999_000_000)
        return record
    }

    private func contribution(_ token: String = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", key: String = "nc:w9",
                              name: String = "Lake Loop", kind: ContributionKind = .nomination,
                              at sentAt: Date = Date(timeIntervalSince1970: 1_990_000_000)) -> Contribution {
        Contribution(claimToken: token, kind: kind, trailKey: key, trailName: name, sentAt: sentAt)
    }

    /// A service holding `items`, as a phone that sent them would.
    private func service(_ items: [Contribution], store: FakeStatuses, clock: Clock,
                         defaults d: UserDefaults? = nil) throws -> (ContributionService, UserDefaults) {
        let d = try d ?? defaults()
        let s = ContributionService(store: store, defaults: d, now: { clock.now })
        for item in items.reversed() { s.noteSent(item) }
        return (s, d)
    }

    // MARK: Vocabulary: the same as docs/staff/contribution-status.js

    private struct JSKind: Equatable {
        let key: String
        let label: String
        let statuses: [String]
        let statusLabels: [String]
    }

    /// Reads contribution-status.js line by line, strictly: inside
    /// CONTRIBUTION_KINDS every line must be one this parser understands,
    /// so a status written another way is an issue, never silently skipped.
    private func vocabularyFromJS() throws -> (prefix: String, kinds: [JSKind]) {
        let text = try String(contentsOf: repo.appendingPathComponent("docs/staff/contribution-status.js"), encoding: .utf8)
        let prefix = try #require(text.firstMatch(of: /export const STATUS_RECORD_PREFIX = '([^']*)';/)).1
        var kinds: [JSKind] = []
        var key: String?, label: String?, statuses: [(String, String)] = []
        func flush() {
            if let key, let label {
                kinds.append(JSKind(key: key, label: label, statuses: statuses.map(\.0), statusLabels: statuses.map(\.1)))
            }
            key = nil; label = nil; statuses = []
        }
        let body = try #require(text.range(of: "export const CONTRIBUTION_KINDS = Object.freeze({\n"))
        let close = try #require(text.range(of: "\n});", range: body.upperBound..<text.endIndex))
        let structural: Set<String> = ["    statuses: Object.freeze({", "    }),", "  }),"]
        for line in text[body.upperBound..<close.lowerBound].components(separatedBy: "\n") {
            if structural.contains(line) { continue }
            if let m = line.firstMatch(of: /^  (\w+): Object\.freeze\(\{$/) {
                flush(); key = String(m.1)
            } else if let m = line.firstMatch(of: /^    label: '([^']*)',$/) {
                label = String(m.1)
            } else if let m = line.firstMatch(of: /^      (\w+): '([^']*)',$/) {
                statuses.append((String(m.1), String(m.2)))
            } else {
                Issue.record("contribution-status.js line the test can't read: \(line)")
            }
        }
        flush()
        return (String(prefix), kinds)
    }

    @Test("The vocabulary is exactly docs/staff/contribution-status.js: kinds, statuses, labels, order and the name prefix")
    func vocabularyMirrorsDashboard() throws {
        let js = try vocabularyFromJS()
        #expect(js.kinds.count == 2, "the parser found every kind")
        #expect(js.prefix == ContributionStatuses.recordPrefix)
        let swift = ContributionKind.allCases.map {
            JSKind(key: $0.rawValue, label: $0.label, statuses: $0.statuses.map(\.key), statusLabels: $0.statuses.map(\.label))
        }
        #expect(js.kinds == swift)
    }

    @Test("Hard-coded too, so a change to both files at once is still a decision; nothing negative")
    func vocabularyPinned() {
        #expect(ContributionKind.allCases.map(\.rawValue) == ["nomination", "suggestion"])
        #expect(ContributionKind.nomination.statuses.map(\.key) == ["featured"])
        #expect(ContributionKind.suggestion.statuses.map(\.key) == ["added"])
        #expect(ContributionStatuses.recordPrefix == "status.")
        let labels = ContributionKind.allCases.flatMap { $0.statuses.map(\.label) } + [ContributionStatuses.sentLabel]
        for word in ["not", "reject", "declin", "denied", "chosen"] {
            #expect(!labels.contains { $0.lowercased().contains(word) }, "no negative status: \(word)")
        }
    }

    @Test("Statuses are case-sensitive and belong to their own kind")
    func statusesAreExact() {
        #expect(ContributionKind.nomination.statusLabel("featured") == "Featured")
        #expect(ContributionKind.nomination.statusLabel("Featured") == nil)
        #expect(ContributionKind.nomination.statusLabel("added") == nil, "a suggestion's status")
        #expect(ContributionKind.suggestion.statusLabel("featured") == nil)
        #expect(ContributionKind(rawValue: "Nomination") == nil)
    }

    // MARK: Claim token and status name

    @Test("The status name is status.<sha256 hex of the token's text>: the dashboard's own test vector")
    func statusNameTestVector() throws {
        #expect(ContributionStatuses.recordName(claimToken: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
                == "status.949960179bb0c122dce42afa24e79611f32cbea403a75ffe8b4d5c07e73ed951")
        // The same vector, read from the dashboard's test, so the two can't drift.
        let test = try String(contentsOf: repo.appendingPathComponent("tests/staff/contribution-status.test.mjs"), encoding: .utf8)
        let token = try #require(test.firstMatch(of: /const TOKEN = '([^']+)';/)).1
        let name = try #require(test.firstMatch(of: /const TOKEN_NAME = '([^']+)';/)).1
        #expect(ContributionStatuses.recordName(claimToken: String(token)) == String(name))
        // Exactly the text: case is not folded.
        #expect(ContributionStatuses.recordName(claimToken: String(token).lowercased()) != String(name))
    }

    @Test("A token is a fresh random UUID the dashboard accepts; the name comes from it alone, never from the trail or the account")
    func tokenAndNameNotDerivable() {
        let a = ContributionStatuses.newClaimToken()
        let b = ContributionStatuses.newClaimToken()
        #expect(a != b)
        // The dashboard's isClaimToken.
        #expect(a.wholeMatch(of: /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/) != nil)
        let name = ContributionStatuses.recordName(claimToken: a)
        #expect(name.wholeMatch(of: /status\.[0-9a-f]{64}/) != nil)
        #expect(name == ContributionStatuses.recordName(claimToken: a), "stable for one token")
        #expect(name != ContributionStatuses.recordName(claimToken: b))
        func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        for guess in ["nc:w9\n_me", "_me\nnc:w9", "nc:w9", "_me", "nc:w9_me"] {
            #expect(name != "status." + sha(guess))
        }
    }

    // MARK: The nomination record

    @Test("A nomination's name is random: nobody can compute it from the account and the trail")
    func nominationName() {
        let a = TrailNominations.record(for: lakeLoop, note: "", claimToken: "T").recordID.recordName
        let b = TrailNominations.record(for: lakeLoop, note: "", claimToken: "T").recordID.recordName
        #expect(a.wholeMatch(of: /nomination\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil)
        #expect(a != b, "the same trail and token: still a new name")
        func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        #expect(a != "nomination." + sha("nc:w9\n_me"), "not the old guessable hash")
        #expect(!a.contains("nc:w9") && !a.contains("T"))
    }

    @Test("A nomination holds the trail, the note and the claim token, and nothing about the nominator")
    func nominationFields() {
        let record = TrailNominations.record(for: lakeLoop, note: " Shady \n", claimToken: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        #expect(record.recordType == "TrailNomination")
        #expect(record.allKeys().sorted()
                == ["claimToken", "latitude", "lengthMeters", "longitude", "note", "region", "trailKey", "trailName"])
        #expect(record["claimToken"] as? String == "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        #expect(record["note"] as? String == "Shady")
        #expect(record["trailKey"] as? String == "nc:w9")
    }

    /// The non-system fields of `type` in cloudkit/schema.ckdb.
    private func schemaFields(_ type: String) throws -> [String] {
        let schema = try String(contentsOf: repo.appendingPathComponent("cloudkit/schema.ckdb"), encoding: .utf8)
        let start = try #require(schema.range(of: "RECORD TYPE \(type) ("))
        let end = try #require(schema.range(of: ");", range: start.upperBound..<schema.endIndex))
        return schema[start.upperBound..<end.lowerBound].components(separatedBy: "\n")
            .compactMap { $0.firstMatch(of: /^\s+"?([a-zA-Z]\w*)"?\s+[A-Z]/).map { String($0.1) } }
            .filter { $0 != "GRANT" }
            .sorted()
    }

    @Test("The schema has exactly the nomination fields the app writes, and the status fields it reads")
    func schemaMatches() throws {
        let record = TrailNominations.record(for: lakeLoop, note: "x", claimToken: "T")
        #expect(try schemaFields("TrailNomination") == record.allKeys().sorted())
        #expect(try schemaFields("ContributionStatus") == ContributionStatuses.fields.sorted())
    }

    // MARK: Sending, and keeping the token

    @Test("Sending writes a fresh token in the record and keeps token, trail, name and time on this phone")
    func sendKeepsToken() async throws {
        let clock = Clock()
        let d = try defaults()
        let (contributions, _) = try service([], store: FakeStatuses(), clock: clock, defaults: d)
        let store = FakeNominations()
        let sent = await TrailNominationSubmission.submit(lakeLoop, note: "", store: store, contributions: contributions,
                                                          canPost: {}, makeToken: { "0B4E1D7A-2F3C-4A5B-8C9D-AEBFC0D1E2F3" },
                                                          now: { clock.now }, sleep: Self.neverFires)
        #expect(sent == .sent)
        let record = try #require(store.saved.first)
        #expect(store.saved.count == 1)
        #expect(record["claimToken"] as? String == "0B4E1D7A-2F3C-4A5B-8C9D-AEBFC0D1E2F3")
        let kept = try #require(contributions.contributions.first)
        #expect(kept.claimToken == "0B4E1D7A-2F3C-4A5B-8C9D-AEBFC0D1E2F3")
        #expect(kept.kind == "nomination")
        #expect(kept.trailKey == "nc:w9")
        #expect(kept.trailName == "Lake Loop")
        #expect(kept.sentAt == clock.now)
        #expect(kept.statusLabel == "Sent")
        // On disk: a new service on the same defaults has it (a relaunch).
        let relaunched = ContributionService(store: FakeStatuses(), defaults: d)
        #expect(relaunched.contributions == [kept])
        #expect(d.data(forKey: ContributionLedger.key) != nil)
    }

    @Test("Each nomination gets its own token by default")
    func defaultTokenIsFresh() async throws {
        let (contributions, _) = try service([], store: FakeStatuses(), clock: Clock())
        let store = FakeNominations()
        let other = TrailRef(trailKey: "nc:w10", trailName: "River Walk", region: "nc", latitude: 35, longitude: -78, lengthMeters: 1)
        _ = await TrailNominationSubmission.submit(lakeLoop, note: "", store: store, contributions: contributions,
                                                   canPost: {}, sleep: Self.neverFires)
        _ = await TrailNominationSubmission.submit(other, note: "", store: store, contributions: contributions,
                                                   canPost: {}, sleep: Self.neverFires)
        let tokens = store.saved.compactMap { $0["claimToken"] as? String }
        #expect(tokens.count == 2 && tokens[0] != tokens[1])
        #expect(Set(contributions.contributions.map(\.claimToken)) == Set(tokens))
    }

    @Test("A trail this phone already nominated is not sent again")
    func onePerTrailOnThisPhone() async throws {
        let (contributions, _) = try service([], store: FakeStatuses(), clock: Clock())
        let store = FakeNominations()
        #expect(!contributions.hasNominated("nc:w9"))
        _ = await TrailNominationSubmission.submit(lakeLoop, note: "", store: store, contributions: contributions,
                                                   canPost: {}, sleep: Self.neverFires)
        #expect(contributions.hasNominated("nc:w9"))
        #expect(!contributions.hasNominated("nc:w10"))
        var canPostCalls = 0
        let again = await TrailNominationSubmission.submit(lakeLoop, note: "", store: store, contributions: contributions,
                                                           canPost: { canPostCalls += 1 }, sleep: Self.neverFires)
        #expect(again == .alreadyNominated)
        #expect(store.saved.count == 1)
        #expect(canPostCalls == 0, "decided on the phone, before anything else")
        #expect(contributions.contributions.count == 1)
    }

    @Test("A token that wasn't sent is never kept: failure, refusal, a clash, the deadline")
    func unsentTokensAreDropped() async throws {
        let (contributions, _) = try service([], store: FakeStatuses(), clock: Clock())
        let failing = FakeNominations()
        failing.error = CKError(.networkUnavailable)
        #expect(await TrailNominationSubmission.submit(lakeLoop, note: "", store: failing, contributions: contributions,
                                                       canPost: {}, sleep: Self.neverFires) == .failed(TrailNominations.failedMessage))
        failing.error = CKError(.serverRecordChanged)
        #expect(await TrailNominationSubmission.submit(lakeLoop, note: "", store: failing, contributions: contributions,
                                                       canPost: {}, sleep: Self.neverFires) == .alreadyNominated)
        failing.error = CKError(.notAuthenticated)
        #expect(await TrailNominationSubmission.submit(lakeLoop, note: "", store: failing, contributions: contributions,
                                                       canPost: {}, sleep: Self.neverFires) == .failed(TrailNominations.signInMessage))
        let refused = FakeNominations()
        #expect(await TrailNominationSubmission.submit(lakeLoop, note: "", store: refused, contributions: contributions,
                                                       canPost: { throw CommunityAccessError.suspended(until: nil) },
                                                       sleep: Self.neverFires) == .failed(CommunityAccessError.suspended(until: nil).message))
        #expect(refused.saved.isEmpty)
        let slow = FakeNominations()
        slow.hangs = true
        #expect(await TrailNominationSubmission.submit(lakeLoop, note: "", store: slow, contributions: contributions,
                                                       canPost: {}, sleep: { _ in }) == .failed(TrailNominations.failedMessage))
        #expect(contributions.contributions.isEmpty)
        #expect(!contributions.hasNominated("nc:w9"), "a failed send can be tried again")
    }

    @Test("A Debug build's missing schema says so; the guard is walker reports' (probe first, nothing saved when refused)")
    func debugGuardMessage() {
        #expect(TrailNominations.outcome(of: TrailFactReportSchemaMissing()) == .failed(TrailNominations.schemaMissingMessage))
    }

    // MARK: Tolerant decode

    @Test("A status decodes only when every part checks out; anything else stays Sent")
    func tolerantDecode() {
        let item = contribution()
        let token = item.claimToken
        #expect(ContributionStatuses.status(from: statusRecord(token: token), for: item) == "featured")
        let refused: [(String, CKRecord)] = [
            ("another type under the name", statusRecord(token: token, type: "TrailNomination")),
            ("another name", statusRecord(token: token, name: ContributionStatuses.recordName(claimToken: "other"))),
            ("unknown kind", statusRecord(token: token, kind: "review")),
            ("kind in another case", statusRecord(token: token, kind: "Nomination")),
            ("another kind than the contribution's", statusRecord(token: token, kind: "suggestion", status: "added")),
            ("unknown status", statusRecord(token: token, status: "shortlisted")),
            ("status in another case", statusRecord(token: token, status: "Featured")),
            ("another kind's status", statusRecord(token: token, status: "added")),
            ("a negative status", statusRecord(token: token, status: "rejected")),
            ("no kind", statusRecord(token: token, kind: nil)),
            ("no status", statusRecord(token: token, status: nil)),
            ("status not a string", statusRecord(token: token, status: 1 as NSNumber)),
            ("another trail", statusRecord(token: token, trailKey: "nc:w10")),
            ("no trail", statusRecord(token: token, trailKey: nil)),
        ]
        for (why, record) in refused {
            #expect(ContributionStatuses.status(from: record, for: item) == nil, "\(why)")
        }
    }

    @Test("A stored list with an entry this version can't read keeps the rest")
    func lossyLedger() throws {
        let d = try defaults()
        let good = contribution()
        let json = """
        [{"claimToken":"x"},
         {"claimToken":"\(good.claimToken)","kind":"nomination","trailKey":"nc:w9","trailName":"Lake Loop","sentAt":0,"future":1}]
        """
        d.set(Data(json.utf8), forKey: ContributionLedger.key)
        let list = ContributionService(store: FakeStatuses(), defaults: d).contributions
        #expect(list.map(\.claimToken) == [good.claimToken])
        #expect(list.first?.bannerShown == false && list.first?.notified == false)
    }

    // MARK: Fetching

    @Test("Asks for every token's status name and nothing else; a found status is Featured, a missing one Sent")
    func fetchAndApply() async throws {
        let store = FakeStatuses()
        let a = contribution("AAAAAAAA-0000-4000-8000-000000000001", key: "nc:w9", name: "Lake Loop")
        let b = contribution("BBBBBBBB-0000-4000-8000-000000000002", key: "nc:w10", name: "River Walk")
        store.records[ContributionStatuses.recordName(claimToken: a.claimToken)] = statusRecord(token: a.claimToken)
        let (s, _) = try service([a, b], store: store, clock: Clock())
        #expect(await s.refresh())
        #expect(store.asked == [[a, b].map { ContributionStatuses.recordName(claimToken: $0.claimToken) }.sorted()])
        #expect(s.contributions.first { $0.id == a.id }?.statusLabel == "Featured")
        #expect(s.contributions.first { $0.id == b.id }?.statusLabel == "Sent")
        #expect(!(store.asked.first ?? []).contains { $0.contains(a.claimToken) }, "the token itself never leaves the phone")
    }

    @Test("A withdrawn feature goes back to Sent; a name with no answer, or a failed fetch, keeps what was known")
    func withdrawalAndFailures() async throws {
        let clock = Clock()
        let store = FakeStatuses()
        let a = contribution()
        let name = ContributionStatuses.recordName(claimToken: a.claimToken)
        store.records[name] = statusRecord(token: a.claimToken)
        let (s, d) = try service([a], store: store, clock: clock)
        await s.refresh()
        #expect(s.contributions[0].statusLabel == "Featured")
        store.unanswered = [name]
        await s.refresh()
        #expect(s.contributions[0].statusLabel == "Featured", "no answer for the name: unchanged")
        store.unanswered = []
        store.error = CKError(.networkUnavailable)
        #expect(await s.refresh() == false)
        #expect(s.contributions[0].statusLabel == "Featured", "a failed fetch keeps the cache")
        store.error = nil
        store.records = [:]
        await s.refresh()
        #expect(s.contributions[0].statusLabel == "Sent", "withdrawn: no record")
        #expect(s.contributions[0].reachedAt != nil, "but it was featured once, and that is remembered")
        #expect(ContributionService(store: store, defaults: d).contributions[0].statusLabel == "Sent", "saved")
    }

    @Test("Fetched at most daily, retried 10 minutes after a failure; the screen and pull to refresh always ask; nothing to ask, no fetch")
    func fetchFrequency() async throws {
        let clock = Clock()
        let store = FakeStatuses()
        let (empty, _) = try service([], store: store, clock: clock)
        #expect(await empty.refreshIfDue() == false)
        #expect(await empty.refresh() == false)
        #expect(store.asked.isEmpty, "no contributions: no CloudKit traffic")

        let (s, _) = try service([contribution()], store: store, clock: clock)
        #expect(await s.refreshIfDue())
        #expect(store.asked.count == 1)
        clock.now += 86_400 - 1
        #expect(await s.refreshIfDue() == false)
        #expect(store.asked.count == 1, "under a day")
        #expect(await s.refresh(), "the screen opening asks anyway")
        #expect(store.asked.count == 2)
        clock.now += 86_400
        store.error = CKError(.networkUnavailable)
        #expect(await s.refreshIfDue() == false)
        #expect(store.asked.count == 3)
        clock.now += 599
        await s.refreshIfDue()
        #expect(store.asked.count == 3, "waits 10 minutes after a failure")
        clock.now += 1
        store.error = nil
        #expect(await s.refreshIfDue())
        #expect(store.asked.count == 4)
    }

    // MARK: Saying so, once

    @Test("The banner announces a newly featured contribution once, even across relaunches and a re-feature")
    func bannerOnce() async throws {
        let store = FakeStatuses()
        let a = contribution()
        let name = ContributionStatuses.recordName(claimToken: a.claimToken)
        let (s, d) = try service([a], store: store, clock: Clock())
        #expect(s.takeBanner().isEmpty, "Sent: nothing to say")
        store.records[name] = statusRecord(token: a.claimToken)
        await s.refresh()
        #expect(s.takeBanner().map(\.id) == [a.id])
        #expect(s.takeBanner().isEmpty, "once")
        let relaunched = ContributionService(store: store, defaults: d)
        #expect(relaunched.takeBanner().isEmpty, "once, on disk")
        store.records = [:]
        await relaunched.refresh()
        store.records[name] = statusRecord(token: a.claimToken)
        await relaunched.refresh()
        #expect(relaunched.takeBanner().isEmpty, "withdrawn and featured again: still once")
    }

    @Test("Banner and notification copy name the trail and say Featured")
    func copy() {
        var a = contribution("A", name: "Lake Loop")
        #expect(ContributionMessages.banner(for: [a]) == nil, "Sent: nothing")
        a.status = "featured"
        var b = contribution("B", key: "nc:w10", name: "River Walk")
        b.status = "featured"
        #expect(ContributionMessages.banner(for: [a]) == "Your nomination of Lake Loop is now Featured")
        #expect(ContributionMessages.banner(for: [a, b]) == "Your nominations of Lake Loop and River Walk are now Featured")
        let one = ContributionMessages.notification(for: [a])
        #expect(one?.title == "Your nomination is Featured")
        #expect(one?.body == "Your nomination of Lake Loop is now Featured. Walkers nearby see it in Trails. Thanks for the tip.")
        #expect(ContributionMessages.notification(for: [a, b])?.title == "Your nominations are Featured")
        #expect(ContributionMessages.thanksDetail.contains("If it is featured you will see it here"))
    }

    private func notifications(_ status: UNAuthorizationStatus) throws -> (NotificationService, FakeNotificationCenter) {
        let center = FakeNotificationCenter(status: status)
        return (NotificationService(center: center, defaults: try defaults()), center)
    }

    @Test("The background task fetches when due and sends one local notification per contribution, once")
    func backgroundNotifiesOnce() async throws {
        let clock = Clock()
        let store = FakeStatuses()
        let a = contribution()
        let (s, d) = try service([a], store: store, clock: clock)
        let (notes, center) = try notifications(.authorized)

        #expect(await s.backgroundCheck(notifications: notes) == 0, "Sent: nothing to say")
        #expect(center.added.isEmpty)
        #expect(store.asked.count == 1)

        store.records[ContributionStatuses.recordName(claimToken: a.claimToken)] = statusRecord(token: a.claimToken)
        #expect(await s.backgroundCheck(notifications: notes) == 0, "not due yet: no fetch, so nothing new")
        #expect(store.asked.count == 1)

        clock.now += 86_400
        #expect(await s.backgroundCheck(notifications: notes) == 1)
        #expect(store.asked.count == 2)
        let request = try #require(center.added.first)
        #expect(center.added.count == 1)
        #expect(request.identifier == "contribution-featured")
        #expect(request.trigger == nil, "local, now: not a push")
        #expect(request.content.body.contains("Lake Loop"))

        clock.now += 86_400
        #expect(await s.backgroundCheck(notifications: notes) == 0)
        #expect(center.added.count == 1, "once")
        let relaunched = ContributionService(store: store, defaults: d, now: { clock.now })
        #expect(await relaunched.backgroundCheck(notifications: notes) == 0)
        #expect(center.added.count == 1, "once, on disk")
    }

    @Test("Quiet delivery counts; with notifications off nothing is marked, and the banner still says it")
    func backgroundRespectsAuthorization() async throws {
        let store = FakeStatuses()
        let a = contribution()
        store.records[ContributionStatuses.recordName(claimToken: a.claimToken)] = statusRecord(token: a.claimToken)

        let (quiet, quietCenter) = try notifications(.provisional)
        let (s1, _) = try service([a], store: store, clock: Clock())
        #expect(await s1.backgroundCheck(notifications: quiet) == 1)
        #expect(quietCenter.added.count == 1)

        let (denied, deniedCenter) = try notifications(.denied)
        let (s2, _) = try service([a], store: store, clock: Clock())
        #expect(await s2.backgroundCheck(notifications: denied) == 0)
        #expect(deniedCenter.added.isEmpty)
        #expect(deniedCenter.authRequests.isEmpty, "never asks for permission: no new prompt")
        #expect(s2.contributions[0].notified == false)
        #expect(s2.takeBanner().map(\.id) == [a.id])
    }

    @Test("Seen on the banner first: no notification about it afterwards")
    func bannerBeforeNotification() async throws {
        let store = FakeStatuses()
        let a = contribution()
        store.records[ContributionStatuses.recordName(claimToken: a.claimToken)] = statusRecord(token: a.claimToken)
        let (s, _) = try service([a], store: store, clock: Clock())
        await s.refresh()
        #expect(s.takeBanner().count == 1)
        let (notes, center) = try notifications(.authorized)
        #expect(await s.backgroundCheck(notifications: notes) == 0)
        #expect(center.added.isEmpty)
    }

    @Test("The notification kind has a stable identifier and isn't hidden behind a Settings toggle")
    func notificationKind() async throws {
        #expect(NotificationKind.contributionFeatured.identifier == "contribution-featured")
        #expect(NotificationKind.contributionFeatured.preferenceKey == nil)
        #expect(NotificationKind.contributionFeatured.interruptionLevel == .active)
        let (notes, _) = try notifications(.authorized)
        #expect(notes.isEnabled(.contributionFeatured))
    }

    // MARK: The empty state

    @Test("With nothing sent the screen is empty and explains nominating; one sent and it isn't")
    func emptyState() throws {
        let (s, _) = try service([], store: FakeStatuses(), clock: Clock())
        #expect(s.contributions.isEmpty)
        #expect(ContributionMessages.emptyMessage.contains("Nominate a trail"))
        #expect(ContributionMessages.emptyMessage.contains("Featured"))
        s.noteSent(contribution())
        #expect(!s.contributions.isEmpty)
    }

    // MARK: No remote push

    @Test("Under tests the app's status store can't reach CloudKit")
    func testsNeverReachCloudKit() {
        #expect(ContributionService.defaultStore() is NoContributionStatusStore)
    }

    @Test("No remote-push code path: nothing registers for pushes or subscribes, and contributions schedule only through NotificationService")
    func noRemotePush() throws {
        let sources = repo.appendingPathComponent("PoCSquat")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "the walk found the app's sources")
        let forbidden = ["registerForRemoteNotifications", "didReceiveRemoteNotification", "CKQuerySubscription",
                         "CKDatabaseSubscription", "CKRecordZoneSubscription", "CKModifySubscriptionsOperation",
                         "CKSubscription"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in forbidden {
                #expect(!text.contains(word), "\(file.lastPathComponent) uses \(word)")
            }
        }
        let contributions = try String(contentsOf: sources.appendingPathComponent("Services/Trails/Contributions.swift"), encoding: .utf8)
        #expect(!contributions.contains("UNUserNotificationCenter"))
        #expect(contributions.contains("notifications.schedule(.contributionFeatured"))
    }
}
