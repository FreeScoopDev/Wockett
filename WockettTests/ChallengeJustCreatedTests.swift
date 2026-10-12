import Testing
import CloudKit
@testable import PoCSquat

// ChallengeService.withJustCreated: a challenge created on the list screen
// stays visible until CloudKit's query index returns it.

struct ChallengeJustCreatedTests {

    private let now = Date(timeIntervalSince1970: 1_791_806_400) // 2026-10-12 12:00 UTC

    private func challenge(_ name: String, startsDaysAgo: Double = 0, endsIn days: Double = 7) throws -> WalkChallenge {
        let r = CKRecord(recordType: "Challenge", recordID: CKRecord.ID(recordName: name))
        r["title"]     = name as CKRecordValue
        r["startDate"] = now.addingTimeInterval(-startsDaysAgo * 86_400) as CKRecordValue
        r["endDate"]   = now.addingTimeInterval(days * 86_400) as CKRecordValue
        r["goalType"]  = "steps" as CKRecordValue
        r["goalSteps"] = 50_000 as CKRecordValue
        return try #require(WalkChallenge(record: r))
    }

    private func names(_ list: [WalkChallenge]) -> [String] { list.map(\.id.recordName) }

    @Test func aChallengeTheFetchMissed_isShown() throws {
        let fetched = [try challenge("older", startsDaysAgo: 3)]
        let mine = try challenge("mine")
        #expect(names(ChallengeService.withJustCreated(fetched, justCreated: [mine], now: now)) == ["older", "mine"])
    }

    @Test func onceTheFetchHasIt_itIsNotDoubled() throws {
        let mine = try challenge("mine")
        let fetched = [try challenge("older", startsDaysAgo: 3), mine]
        #expect(names(ChallengeService.withJustCreated(fetched, justCreated: [mine], now: now)) == ["older", "mine"])
    }

    @Test func anEndedOne_dropsOut() throws {
        let ended = try challenge("mine", startsDaysAgo: 8, endsIn: -1)
        #expect(ChallengeService.withJustCreated([], justCreated: [ended], now: now).isEmpty)
    }

    @Test func nothingCreated_leavesTheFetchAsIs() throws {
        let fetched = [try challenge("b"), try challenge("a", startsDaysAgo: 2)]
        #expect(names(ChallengeService.withJustCreated(fetched, justCreated: [], now: now)) == ["b", "a"])
    }

    @Test func merged_inStartDateOrder() throws {
        let fetched = [try challenge("week-old", startsDaysAgo: 7), try challenge("today")]
        let mine = try challenge("yesterday", startsDaysAgo: 1)
        #expect(names(ChallengeService.withJustCreated(fetched, justCreated: [mine], now: now))
                == ["week-old", "yesterday", "today"])
    }
}
