import Testing
import CloudKit
@testable import PoCSquat

/// Challenge entries no longer publish a per-install device ID (2026-10-12
/// audit, finding 22), and "is this my entry" no longer depends on one.
@MainActor
struct ChallengeEntryOwnerTests {

    private func moderation(me: String?) -> CommunityModerationStore {
        let suite = "ChallengeEntryOwnerTests.\(UUID().uuidString)"
        return CommunityModerationStore(defaults: UserDefaults(suiteName: suite) ?? .standard, myAccount: { me })
    }

    private func entry(name: String = "entry-1", deviceID: String, creator: String) throws -> ChallengeParticipant {
        let r = CKRecord(recordType: "ChallengeEntry", recordID: CKRecord.ID(recordName: name))
        r["displayName"] = "AmberElk"
        r["steps"] = 1_000
        r["deviceID"] = deviceID
        return try #require(ChallengeParticipant(record: r, creator: CKRecord.ID(recordName: creator)))
    }

    @Test("A new entry publishes an empty device ID, and older apps can still read it")
    func newEntryHasNoDeviceID() throws {
        let record = ChallengeService.entryRecord(challengeKey: "c1", displayName: "AmberElk", steps: 4_200)
        #expect(record["deviceID"] as? String == "")
        #expect(record["challengeRecordName"] as? String == "c1")
        #expect(record["steps"] as? Int == 4_200)
        // 1.14 and 1.15 parse an entry only when deviceID is a String.
        #expect(ChallengeParticipant(record: record) != nil)
    }

    @Test("An entry your account created is yours, on any install")
    func mineByAccount() throws {
        let e = try entry(deviceID: "", creator: "_me")
        #expect(e.isMine(moderation: moderation(me: "_me"), joinedEntryNames: [], legacyDeviceID: nil))
        let own = try entry(deviceID: "", creator: CKCurrentUserDefaultName)
        #expect(own.isMine(moderation: moderation(me: nil), joinedEntryNames: [], legacyDeviceID: nil))
    }

    @Test("The entry this install joined with is yours")
    func mineByJoinedEntry() throws {
        let e = try entry(name: "entry-7", deviceID: "", creator: "_someone")
        #expect(e.isMine(moderation: moderation(me: nil), joinedEntryNames: ["entry-7"], legacyDeviceID: nil))
    }

    @Test("A pre-1.16 entry is yours by the device ID this install stored then")
    func mineByLegacyDeviceID() throws {
        let e = try entry(deviceID: "LEGACY-1", creator: "_someone")
        #expect(e.isMine(moderation: moderation(me: "_me"), joinedEntryNames: [], legacyDeviceID: "LEGACY-1"))
        #expect(!e.isMine(moderation: moderation(me: "_me"), joinedEntryNames: [], legacyDeviceID: "LEGACY-2"))
    }

    @Test("Someone else's new entry is never yours, even with no device ID on either side")
    func notMine() throws {
        let e = try entry(deviceID: "", creator: "_someone")
        #expect(!e.isMine(moderation: moderation(me: "_me"), joinedEntryNames: ["entry-9"], legacyDeviceID: nil))
        #expect(!e.isMine(moderation: moderation(me: "_me"), joinedEntryNames: [], legacyDeviceID: ""))
    }
}
