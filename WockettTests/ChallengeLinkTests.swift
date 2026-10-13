import Testing
import Foundation
import CloudKit
@testable import PoCSquat

// ChallengeLink parses URLs from outside the app (Messages, Mail, any web
// page), so everything here is hostile input until it passes the rule.

@MainActor
struct ChallengeLinkTests {

    private let id = "6F1C2B9E-0D3A-4E57-9B1A-2C7D8E9F0A1B"

    private func parse(_ string: String) -> String? {
        guard let url = URL(string: string) else { return nil }
        return ChallengeLink.recordName(from: url)
    }

    // MARK: - Building

    @Test func link_isTheChallengePageWithTheID() {
        #expect(ChallengeLink.url(for: id)?.absoluteString == "https://wockett.app/c/?id=\(id)")
    }

    @Test func link_roundTrips() throws {
        let url = try #require(ChallengeLink.url(for: id))
        #expect(ChallengeLink.recordName(from: url) == id)
    }

    @Test func noLink_forARecordNameOutsideTheRule() {
        #expect(ChallengeLink.url(for: "") == nil)
        #expect(ChallengeLink.url(for: "has space") == nil)
        #expect(ChallengeLink.url(for: "a.b") == nil)
        #expect(ChallengeLink.url(for: String(repeating: "a", count: 101)) == nil)
    }

    // MARK: - Parsing what the link can look like

    @Test func accepts_withAndWithoutTheSlash_andAnyHostCase() {
        #expect(parse("https://wockett.app/c/?id=\(id)") == id)
        #expect(parse("https://wockett.app/c?id=\(id)") == id)
        #expect(parse("https://WOCKETT.app/c/?id=\(id)") == id)
        #expect(parse("https://wockett.app/c/?id=\(id)&utm_source=x") == id)
        #expect(parse("https://wockett.app/c/?id=\(String(repeating: "a", count: 100))") != nil)
    }

    // MARK: - Rejecting everything else

    @Test func rejects_otherHostsSchemesAndPaths() {
        #expect(parse("http://wockett.app/c/?id=\(id)") == nil)
        #expect(parse("https://evil.example/c/?id=\(id)") == nil)
        #expect(parse("https://wockett.app.evil.example/c/?id=\(id)") == nil)
        #expect(parse("https://www.wockett.app/c/?id=\(id)") == nil)
        #expect(parse("https://wockett.app/c/x?id=\(id)") == nil)
        #expect(parse("https://wockett.app/staff/?id=\(id)") == nil)
        #expect(parse("https://wockett.app/?id=\(id)") == nil)
        #expect(parse("wockett://c/?id=\(id)") == nil)
    }

    @Test func rejects_missingEmptyRepeatedOrIllegalIDs() {
        #expect(parse("https://wockett.app/c/") == nil)
        #expect(parse("https://wockett.app/c/?id=") == nil)
        #expect(parse("https://wockett.app/c/?challenge=\(id)") == nil)
        #expect(parse("https://wockett.app/c/?id=\(id)&id=other") == nil)
        #expect(parse("https://wockett.app/c/?id=\(String(repeating: "a", count: 101))") == nil)
        #expect(parse("https://wockett.app/c/?id=a%2Fb") == nil)              // "/"
        #expect(parse("https://wockett.app/c/?id=%3Cscript%3E") == nil)       // "<script>"
        #expect(parse("https://wockett.app/c/?id=abc.") == nil)               // trailing "."
        #expect(parse("https://wockett.app/c/?id=%E2%80%AEabc") == nil)       // bidi override
    }

    // MARK: - Inbox

    @MainActor @Test func inbox_holdsAChallengeLinkOnce() throws {
        let inbox = ChallengeLinkInbox()
        #expect(inbox.post(try #require(URL(string: "https://wockett.app/c/?id=\(id)"))))
        #expect(inbox.consume() == id)
        #expect(inbox.consume() == nil)
    }

    @MainActor @Test func inbox_ignoresOtherURLs() throws {
        let inbox = ChallengeLinkInbox()
        #expect(!inbox.post(try #require(URL(string: "https://evil.example/c/?id=\(id)"))))
        #expect(inbox.pending == nil)
    }

    // MARK: - Which challenges a link may open

    /// A fresh moderation store, so blocks and reports don't leak between tests.
    private func moderation() -> CommunityModerationStore {
        let suite = "ChallengeLinkTests.\(UUID().uuidString)"
        return CommunityModerationStore(defaults: UserDefaults(suiteName: suite) ?? .standard,
                                        myAccount: { "_me" }, notifications: NotificationCenter())
    }

    private let now = Date(timeIntervalSince1970: 1_791_806_400) // 2026-10-12 12:00 UTC

    private func record(type: String = "Challenge", endsIn: TimeInterval = 86_400) -> CKRecord {
        let r = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: id))
        r["title"]      = "Weekend Runfest" as CKRecordValue
        r["authorName"] = "Sam" as CKRecordValue
        r["startDate"]  = now.addingTimeInterval(-86_400) as CKRecordValue
        r["endDate"]    = now.addingTimeInterval(endsIn) as CKRecordValue
        r["goalType"]   = "steps" as CKRecordValue
        r["goalSteps"]  = 50_000 as CKRecordValue
        return r
    }

    private let author = CKRecord.ID(recordName: "_sam")

    @Test func linkable_aRunningChallenge() {
        let challenge = ChallengeService.linkable(record(), creator: author, now: now, moderation: moderation())
        #expect(challenge?.id.recordName == id)
    }

    @Test func notLinkable_endedOrAnotherRecordType() {
        #expect(ChallengeService.linkable(record(endsIn: -1), creator: author, now: now, moderation: moderation()) == nil)
        #expect(ChallengeService.linkable(record(type: "SharedRoute"), creator: author, now: now,
                                          moderation: moderation()) == nil)
    }

    @Test func notLinkable_whatTheListHides() {
        let blocked = moderation()
        blocked.block(CommunityAuthor(name: "Sam", account: "_sam"))
        #expect(ChallengeService.linkable(record(), creator: author, now: now, moderation: blocked) == nil)

        let reported = moderation()
        reported.report(CKRecord.ID(recordName: id))
        #expect(ChallengeService.linkable(record(), creator: author, now: now, moderation: reported) == nil)

        let suspended = moderation()
        suspended.setSuspensions([Suspension(account: "_sam", until: nil)])
        #expect(ChallengeService.linkable(record(), creator: author, now: now, moderation: suspended) == nil)
    }
}
