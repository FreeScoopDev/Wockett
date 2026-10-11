import Testing
import CloudKit
import Foundation
@testable import PoCSquat

/// Deleting a challenge you created (2026-10-11): yours alone, it's deleted;
/// once others have joined, you can only ask, and a moderator removes it.
@MainActor
struct ChallengeDeletionTests {

    private func defaults() -> UserDefaults {
        let name = "ChallengeDeletionTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name) ?? .standard
        d.removePersistentDomain(forName: name)
        return d
    }

    private func store(_ d: UserDefaults) -> CommunityModerationStore {
        CommunityModerationStore(defaults: d, myAccount: { "_me" })
    }

    private func challenge(_ name: String = "c1") throws -> WalkChallenge {
        let r = CKRecord(recordType: "Challenge", recordID: CKRecord.ID(recordName: name))
        r["title"] = "10k a day"
        r["emoji"] = "🥾"
        r["startDate"] = Date()
        r["endDate"] = Date().addingTimeInterval(86_400)
        r["goalSteps"] = 10_000
        r["authorName"] = "MistyOak12"
        return try #require(WalkChallenge(record: r, creator: CKRecord.ID(recordName: "_me")))
    }

    private func entry(_ name: String, by account: String) throws -> ChallengeParticipant {
        let r = CKRecord(recordType: "ChallengeEntry", recordID: CKRecord.ID(recordName: name))
        r["displayName"] = name
        r["steps"] = 100
        r["deviceID"] = "d-\(name)"
        return try #require(ChallengeParticipant(record: r, creator: CKRecord.ID(recordName: account)))
    }

    private final class FakeLister: ChallengeEntryLister {
        var list: [ChallengeParticipant] = []
        var error: Error?
        func entries(of challengeKey: String) async throws -> [ChallengeParticipant] {
            if let error { throw error }
            return list
        }
    }

    private final class FakeDeleter: CommunityRecordDeleter {
        var deleted: [String] = []
        var failFirst: Error?
        func delete(_ id: CKRecord.ID) async throws {
            if let failFirst { self.failFirst = nil; throw failFirst }
            deleted.append(id.recordName)
        }
    }

    private final class FakeReports: CommunityReportStore {
        var saved: [CKRecord] = []
        var error: Error?
        func currentUserRecordName() async throws -> String { "_me" }
        func save(_ record: CKRecord) async throws {
            if let error { throw error }
            saved.append(record)
        }
    }

    // MARK: Who else joined

    @Test("Only other accounts' entries count; yours, signed in or out, don't; unknown ones do")
    func othersJoined() throws {
        let s = store(defaults())
        let entries = [try entry("mine", by: "_me"), try entry("mine2", by: CKCurrentUserDefaultName),
                       try entry("a", by: "_a"), try entry("b", by: "_b")]
        #expect(ChallengeDeletion.othersJoined(entries, moderation: s) == 2)
        #expect(ChallengeDeletion.othersJoined([], moderation: s) == 0)
    }

    @Test("Alone, it's a delete; with others, a request; unreadable, a plain message")
    func plans() async throws {
        let d = defaults()
        let lister = FakeLister()
        lister.list = [try entry("mine", by: "_me")]
        #expect(await ChallengeDeletion.plan(for: try challenge(), lister: lister, moderation: store(d)) == .delete)
        lister.list.append(try entry("a", by: "_a"))
        #expect(await ChallengeDeletion.plan(for: try challenge(), lister: lister, moderation: store(d)) == .request(others: 1))
        lister.error = CKError(.networkUnavailable)
        #expect(await ChallengeDeletion.plan(for: try challenge(), lister: lister, moderation: store(d))
                == .failed("Couldn't check who has joined. Check your connection and try again."))
    }

    // MARK: Deleting

    @Test("Delete removes the challenge, then your tracked entry, and forgets the join")
    func deleteAlone() async throws {
        let d = defaults()
        d.set(["c1": "e1", "c2": "e2"], forKey: ChallengeService.joinedKey)
        let deleter = FakeDeleter()
        let moderation = store(d)
        let c = try challenge()
        #expect(await ChallengeDeletion.delete(c, deleter: deleter, defaults: d, moderation: moderation) == .deleted)
        #expect(deleter.deleted == ["c1", "e1"])
        #expect(d.dictionary(forKey: ChallengeService.joinedKey) as? [String: String] == ["c2": "e2"])
        #expect(moderation.isDeleted(c.id))
    }

    @Test("If the challenge can't be deleted, nothing else is touched")
    func deleteFails() async throws {
        let d = defaults()
        d.set(["c1": "e1"], forKey: ChallengeService.joinedKey)
        let deleter = FakeDeleter()
        deleter.failFirst = CKError(.networkUnavailable)
        let moderation = store(d)
        let c = try challenge()
        #expect(await ChallengeDeletion.delete(c, deleter: deleter, defaults: d, moderation: moderation)
                == .failed("Couldn't delete it. Check your connection and try again."))
        #expect(deleter.deleted.isEmpty)
        #expect(d.dictionary(forKey: ChallengeService.joinedKey) as? [String: String] == ["c1": "e1"])
        #expect(!moderation.isDeleted(c.id))
    }

    // MARK: Requesting

    @Test("A request is a report on the challenge, reason ownerRequest, naming how many joined")
    func requestRecord() throws {
        let record = ChallengeDeletion.requestRecord(for: try challenge(), others: 3, requester: "_me")
        #expect(record.recordType == "CommunityReport")
        #expect(record["targetRecordName"] as? String == "c1")
        #expect(record["targetType"] as? String == "challenge")
        #expect(record["reason"] as? String == "ownerRequest")
        #expect(record["note"] as? String == "The person who created it asked to delete it. 3 other people have joined.")
        #expect(record.recordID.recordName == CommunityReports.recordName(target: "c1", reporter: "_me"))
    }

    @Test("Sending saves once; a second request is 'already sent'")
    func request() async throws {
        let reports = FakeReports()
        #expect(await ChallengeDeletion.request(try challenge(), others: 2, store: reports, knownRequester: { nil }) == .sent)
        #expect(reports.saved.count == 1)
        reports.error = CKError(.serverRecordChanged)
        #expect(await ChallengeDeletion.request(try challenge(), others: 2, store: reports, knownRequester: { nil }) == .alreadySent)
    }

    @Test("The words say what happens")
    func copy() {
        #expect(ChallengeDeletion.deleteMessage == "This removes the challenge and your entry for everyone.")
        #expect(ChallengeDeletion.requestMessage(others: 1)
                == "1 other person has joined, so the Wockett team removes it, with their entries. Send them a request?")
        #expect(ChallengeDeletion.requestMessage(others: 4)
                == "4 other people have joined, so the Wockett team removes it, with their entries. Send them a request?")
    }
}
