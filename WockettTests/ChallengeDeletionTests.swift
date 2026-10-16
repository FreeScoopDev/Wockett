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
        CommunityModerationStore(defaults: d, myAccount: { "_me" }, notifications: NotificationCenter())
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

    private func entry(_ name: String, by account: String?) throws -> ChallengeParticipant {
        let r = CKRecord(recordType: "ChallengeEntry", recordID: CKRecord.ID(recordName: name))
        r["displayName"] = name
        r["steps"] = 100
        r["deviceID"] = "d-\(name)"
        return try #require(ChallengeParticipant(record: r, creator: account.map { CKRecord.ID(recordName: $0) }))
    }

    private final class FakeLister: ChallengeEntryLister {
        var list: [ChallengeParticipant] = []
        var unreadable = 0
        var error: Error?
        func entries(of challengeKey: String) async throws -> (entries: [ChallengeParticipant], unreadable: Int) {
            if let error { throw error }
            return (list, unreadable)
        }
    }

    private static let neverFires: OptimisticVote.Sleep = { _ in try await Task.sleep(for: .seconds(86_400)) }

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

    @Test("A suspended entrant still joined: they count")
    func suspendedCounts() throws {
        let s = store(defaults())
        s.setSuspensions([Suspension(account: "_s", until: nil)])
        #expect(ChallengeDeletion.othersJoined([try entry("s", by: "_s")], moderation: s) == 1)
    }

    @Test("An entrant whose account is unknown counts as someone else")
    func unknownCounts() throws {
        #expect(ChallengeDeletion.othersJoined([try entry("x", by: nil)], moderation: store(defaults())) == 1)
    }

    @Test("An entry that can't be read counts as someone else's: ask, don't delete")
    func unreadableCounts() async throws {
        let lister = FakeLister()
        lister.list = [try entry("mine", by: "_me")]
        lister.unreadable = 1
        #expect(await ChallengeDeletion.plan(for: try challenge(), lister: lister, moderation: store(defaults()), sleep: Self.neverFires)
                == .request(others: 1))
    }

    @Test("A check that doesn't answer in time says so")
    func planTimesOut() async throws {
        final class Hanging: ChallengeEntryLister {
            func entries(of challengeKey: String) async throws -> (entries: [ChallengeParticipant], unreadable: Int) {
                try await Task.sleep(for: .seconds(600))
                return ([], 0)
            }
        }
        #expect(await ChallengeDeletion.plan(for: try challenge(), lister: Hanging(), moderation: store(defaults()), sleep: { _ in })
                == .failed(ChallengeDeletion.timedOut))
    }

    @Test("Alone, it's a delete; with others, a request; unreadable, a plain message")
    func plans() async throws {
        let d = defaults()
        let lister = FakeLister()
        lister.list = [try entry("mine", by: "_me")]
        #expect(await ChallengeDeletion.plan(for: try challenge(), lister: lister, moderation: store(d), sleep: Self.neverFires) == .delete)
        lister.list.append(try entry("a", by: "_a"))
        #expect(await ChallengeDeletion.plan(for: try challenge(), lister: lister, moderation: store(d), sleep: Self.neverFires) == .request(others: 1))
        lister.error = CKError(.networkUnavailable)
        #expect(await ChallengeDeletion.plan(for: try challenge(), lister: lister, moderation: store(d), sleep: Self.neverFires)
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
        let record = ChallengeDeletion.requestRecord(for: try challenge(), others: 3)
        #expect(record.recordType == "CommunityReport")
        #expect(record["targetRecordName"] as? String == "c1")
        #expect(record["targetType"] as? String == "challenge")
        #expect(record["reason"] as? String == "ownerRequest")
        #expect(record["note"] as? String == "The person who created it asked to delete it. 3 other people have joined.")
        #expect(record["targetAuthorName"] as? String == "MistyOak12")
        #expect(record["targetSummary"] as? String == "🥾 10k a day")
        #expect(Set(record.allKeys()) == ["targetRecordName", "targetType", "reason", "note",
                                          "targetAuthorName", "targetSummary"])
    }

    @Test("Every request gets its own random name, so no one can compute it to test whether you asked")
    func requestRandomName() throws {
        let c = try challenge()
        let a = ChallengeDeletion.requestRecord(for: c, others: 1).recordID.recordName
        let b = ChallengeDeletion.requestRecord(for: c, others: 1).recordID.recordName
        #expect(a != b)
        let uuid = try #require(a.split(separator: ".", maxSplits: 1).last)
        #expect(a.hasPrefix("report."))
        #expect(UUID(uuidString: String(uuid)) != nil, "report.<UUID>")
        #expect(String(uuid) == String(uuid).lowercased())
    }

    @Test("One request per challenge per day from this phone; the next day, or another challenge, sends again")
    func requestPerDay() async throws {
        let reports = FakeReports()
        let ledger = CommunityReportLedger(defaults: defaults())
        let utc = try #require(TimeZone(identifier: "UTC"))
        let day1 = Date(timeIntervalSince1970: 2_000_000_000)
        let day2 = day1.addingTimeInterval(86_400)
        let c = try challenge()
        #expect(await ChallengeDeletion.request(c, others: 1, store: reports, ledger: ledger, on: day1, timeZone: utc,
                                                sleep: Self.neverFires) == .sent)
        #expect(await ChallengeDeletion.request(c, others: 1, store: reports, ledger: ledger, on: day1, timeZone: utc,
                                                sleep: Self.neverFires) == .alreadySent)
        #expect(reports.saved.count == 1, "the second ask the same day saves nothing")
        #expect(await ChallengeDeletion.request(c, others: 1, store: reports, ledger: ledger, on: day2, timeZone: utc,
                                                sleep: Self.neverFires) == .sent)
        #expect(await ChallengeDeletion.request(try challenge("c2"), others: 1, store: reports, ledger: ledger, on: day2,
                                                timeZone: utc, sleep: Self.neverFires) == .sent)
        #expect(reports.saved.count == 3)
    }

    @Test("'Today' is the person's own day, not UTC's")
    func requestLocalDay() throws {
        let c = try challenge()
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        // 6 pm in Los Angeles on Oct 11 is already Oct 12 in UTC; 9 am the next day is Oct 12 in both.
        let evening = try #require(ISO8601DateFormatter().date(from: "2026-10-12T01:00:00Z"))
        let nextMorning = try #require(ISO8601DateFormatter().date(from: "2026-10-12T16:00:00Z"))
        let first = ChallengeDeletion.requestEntry(for: c, on: evening, timeZone: la)
        let again = ChallengeDeletion.requestEntry(for: c, on: nextMorning, timeZone: la)
        #expect(first == "request:c1@2026-10-11")
        #expect(first != again, "asking again the next morning is a new request")
    }

    @Test("A request that fails is not remembered, so asking again sends it")
    func requestFailureNotRemembered() async throws {
        let reports = FakeReports()
        let ledger = CommunityReportLedger(defaults: defaults())
        let c = try challenge()
        reports.error = CKError(.networkFailure)
        guard case .failed = await ChallengeDeletion.request(c, others: 2, store: reports, ledger: ledger, sleep: Self.neverFires) else {
            Issue.record("a network failure is a failure"); return
        }
        reports.error = nil
        #expect(await ChallengeDeletion.request(c, others: 2, store: reports, ledger: ledger, sleep: Self.neverFires) == .sent)
        #expect(reports.saved.count == 1)
    }

    @Test("A name clash is a failure, not 'already sent': only this phone's own record says that")
    func requestClashFails() async throws {
        let reports = FakeReports()
        reports.error = CKError(.serverRecordChanged)
        let outcome = await ChallengeDeletion.request(try challenge(), others: 2, store: reports,
                                                      ledger: CommunityReportLedger(defaults: defaults()), sleep: Self.neverFires)
        #expect(outcome == .failed("Couldn't send the request. Check your connection and try again."))
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
