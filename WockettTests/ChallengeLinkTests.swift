import Testing
import Foundation
@testable import PoCSquat

// ChallengeLink parses URLs from outside the app (Messages, Mail, any web
// page), so everything here is hostile input until it passes the rule.

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
}
