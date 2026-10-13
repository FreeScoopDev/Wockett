import Testing
import CloudKit
import Foundation
@testable import PoCSquat

/// Settings > Community > Delete my community data (audit 2026-10-12,
/// finding 15): every public type you can delete, found by creator and by
/// what this phone remembers; challenges others joined are asked for, not
/// deleted; failures are reported per type.
@MainActor
struct CommunityDataDeletionTests {

    // MARK: What it covers (hard-coded on purpose)

    @Test("The delete covers exactly these public record types")
    func coveredTypes() {
        #expect(CommunityDataDeletion.kinds.map(\.recordType)
                == ["CommunityVote", "WocketAchievement", "SharedRoute", "ChallengeEntry", "Challenge", "CommunityName"])
    }

    @Test("Reports and trail suggestions are named as what it can't delete")
    func undeletableTypes() {
        #expect(CommunityDataDeletion.undeletable.map(\.recordType) == ["CommunityReport", "TrailNomination"])
        #expect(CommunityDataDeletion.undeletableNote.contains("Reports and trail suggestions"))
    }

    @Test("Every type the delete covers is queryable by creator in the schema; the two it can't delete grant the creator nothing")
    func schemaAgrees() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cloudkit/schema.ckdb")
        let schema = try String(contentsOf: url, encoding: .utf8)
        func block(_ type: String) throws -> String {
            let start = try #require(schema.range(of: "RECORD TYPE \(type) ("))
            let end = try #require(schema.range(of: ");", range: start.upperBound..<schema.endIndex))
            return String(schema[start.upperBound..<end.lowerBound])
        }
        for type in CommunityDataDeletion.kinds.map(\.recordType) {
            let b = try block(type)
            #expect(b.range(of: #""___createdBy"\s+REFERENCE QUERYABLE"#, options: .regularExpression) != nil, "\(type)")
            #expect(b.contains(#"GRANT WRITE TO "_creator""#), "\(type): the creator can delete it")
        }
        for type in CommunityDataDeletion.undeletable.map(\.recordType) {
            #expect(!(try block(type)).contains("_creator"), "\(type)")
        }
        #expect(try block("CommunityBlockList").contains("entries         STRING"))
    }

    // MARK: Fakes

    private final class FakeStore: CommunityDataStore {
        var me = "_me"
        var userError: Error?
        var byType: [String: [CKRecord]] = [:]
        var queryErrors: [String: Error] = [:]
        var deleteErrors: [String: Error] = [:]
        var deleted: [String] = []

        func currentUser() async throws -> String {
            if let userError { throw userError }
            return me
        }
        func records(ofType type: String, createdBy account: String) async throws -> [CKRecord] {
            #expect(account == me)
            if let error = queryErrors[type] { throw error }
            return byType[type] ?? []
        }
        func delete(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Error?] {
            var out: [CKRecord.ID: Error?] = [:]
            for id in ids {
                if let error = deleteErrors[id.recordName] {
                    out[id] = .some(error)
                } else {
                    deleted.append(id.recordName)
                    out[id] = .some(nil)
                }
            }
            return out
        }
    }

    private func defaults() -> UserDefaults {
        let name = "CommunityDataDeletionTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name) ?? .standard
        d.removePersistentDomain(forName: name)
        return d
    }

    private func record(_ type: String, _ name: String, _ fields: [String: CKRecordValue] = [:]) -> CKRecord {
        let r = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name))
        for (k, v) in fields { r[k] = v }
        return r
    }

    private func challenge(_ name: String) -> CKRecord {
        record("Challenge", name, ["title": "10k" as CKRecordValue, "startDate": Date() as CKRecordValue,
                                   "endDate": Date().addingTimeInterval(86_400) as CKRecordValue,
                                   "goalSteps": 10_000 as CKRecordValue, "authorName": "Me" as CKRecordValue])
    }

    private func runner(_ store: FakeStore, _ d: UserDefaults,
                        plan: @escaping (WalkChallenge) async -> ChallengeDeletion.Plan = { _ in .delete },
                        requested: @escaping (String) -> Void = { _ in },
                        nameDeleted: @escaping () -> Void = {}) -> CommunityDataDeletionRun {
        CommunityDataDeletionRun(
            store: store, defaults: d,
            moderation: CommunityModerationStore(defaults: d, myAccount: { "_me" }, notifications: NotificationCenter()),
            plan: plan,
            request: { c, _ in requested(c.id.recordName); return .sent },
            nameDeleted: nameDeleted)
    }

    // MARK: Behaviour

    @Test("Deletes every type's records found by creator, in order, and reports counts")
    func deletesEverything() async {
        let store = FakeStore()
        store.byType = [
            "CommunityVote": [record("CommunityVote", "vote.p1._me")],
            "WocketAchievement": [record("WocketAchievement", "post1")],
            "SharedRoute": [record("SharedRoute", "route1"), record("SharedRoute", "route2")],
            "ChallengeEntry": [record("ChallengeEntry", "entry1")],
            "Challenge": [challenge("ch1")],
            "CommunityName": [record("CommunityName", "name.mistyoak42")]
        ]
        var progress: [CommunityDataKind] = []
        var nameGone = 0
        let report = await runner(store, defaults(), nameDeleted: { nameGone += 1 }).run { progress.append($0) }
        #expect(progress == CommunityDataDeletion.kinds)
        #expect(store.deleted == ["vote.p1._me", "post1", "route1", "route2", "entry1", "ch1", "name.mistyoak42"])
        #expect(report.results.map(\.deleted) == [1, 1, 2, 1, 1, 1])
        #expect(!report.hasFailures)
        #expect(nameGone == 1, "the name claim is forgotten so the next post claims a new one")
    }

    @Test("Records this phone remembers are deleted even when the creator query fails, and the failure is said")
    func rememberedWhenQueryFails() async {
        let d = defaults()
        d.set(["route1"], forKey: CommunityRouteService.publishedKey)
        d.set(["c1": "entry1"], forKey: ChallengeService.joinedKey)
        d.set(["post9"], forKey: AchievementFeedService.likedKey)
        d.set(["route7"], forKey: CommunityRouteService.votedKey)
        d.set("MistyOak42", forKey: CommunityNameService.claimedKey)
        d.set("_me", forKey: CommunityNameService.claimedOwnerKey)
        let store = FakeStore()
        for kind in CommunityDataDeletion.kinds { store.queryErrors[kind.recordType] = CKError(.invalidArguments) }
        let report = await runner(store, d).run()
        #expect(store.deleted == ["vote.post9._me", "vote.route7._me", "route1", "entry1", "name.mistyoak42"])
        #expect(report.results.allSatisfy { $0.failures.count == 1 })
        #expect(report.hasFailures)
        #expect(d.stringArray(forKey: CommunityRouteService.publishedKey) == [])
        #expect((d.dictionary(forKey: ChallengeService.joinedKey) as? [String: String]) == [:])
        #expect(d.stringArray(forKey: CommunityRouteService.votedKey) == ["route7"], "vote marks stay: a badge counts them")
        #expect(d.bool(forKey: UnsentVoteCatchUp.doneKey), "the catch-up must never re-send deleted votes")
    }

    @Test("A challenge others joined is asked for, not deleted")
    func challengeWithOthers() async {
        let store = FakeStore()
        store.byType = ["Challenge": [challenge("solo"), challenge("shared")]]
        var asked: [String] = []
        let report = await runner(store, defaults(),
                                  plan: { $0.id.recordName == "shared" ? .request(others: 2) : .delete },
                                  requested: { asked.append($0) }).run()
        #expect(store.deleted == ["solo"])
        #expect(asked == ["shared"])
        let challenges = report.results.first { $0.kind == .challenges }
        #expect(challenges?.deleted == 1)
        #expect(challenges?.requested == 1)
    }

    @Test("A record that won't delete is reported, and the rest still go")
    func partialFailure() async {
        let store = FakeStore()
        store.byType = ["SharedRoute": [record("SharedRoute", "ok"), record("SharedRoute", "stuck")]]
        store.deleteErrors = ["stuck": CKError(.networkFailure)]
        let report = await runner(store, defaults()).run()
        let routes = report.results.first { $0.kind == .routes }
        #expect(routes?.deleted == 1)
        #expect(routes?.failures == ["Couldn't reach iCloud. Check your connection and try again."])
        #expect(report.hasFailures)
    }

    @Test("Signed out of iCloud: nothing runs and it says to sign in")
    func signedOut() async {
        let store = FakeStore()
        store.userError = CKError(.notAuthenticated)
        let report = await runner(store, defaults()).run()
        #expect(report.stopped == CommunityDataDeletion.signInMessage)
        #expect(report.results.isEmpty)
        #expect(store.deleted.isEmpty)
    }

    @Test("A remembered vote that was never saved isn't counted as deleted")
    func unsavedVoteNotCounted() async {
        let d = defaults()
        d.set(["post9"], forKey: AchievementFeedService.likedKey)
        let store = FakeStore()
        store.deleteErrors = ["vote.post9._me": CKError(.unknownItem)]
        let report = await runner(store, d).run()
        let votes = report.results.first { $0.kind == .votes }
        #expect(votes?.deleted == 0)
        #expect(votes?.failures == [])
        #expect(votes?.summary == "nothing to delete")
    }

    @Test("The support email carries the account ID a moderator needs")
    func supportEmail() throws {
        let url = try #require(CommunityDataDeletion.supportMailURL(account: "_abc123"))
        let text = try #require(url.absoluteString.removingPercentEncoding)
        #expect(text.hasPrefix("mailto:support@wockett.app"))
        #expect(text.contains("My community account ID: _abc123"))
    }
}
