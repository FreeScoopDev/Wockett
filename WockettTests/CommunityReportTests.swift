import Testing
import CloudKit
import Foundation
import Observation
@testable import PoCSquat

/// The email a community report opens (`CommunityReport`, `SupportContact`).
/// App Review 1.2 wants reports to reach the developer, so what matters here
/// is that the email names the right item and survives being a URL.
@MainActor
struct CommunityReportTests {

    /// Reads a mailto URL back the way a mail app does.
    private func decoded(_ url: URL?) throws -> (to: String, subject: String?, body: String?) {
        let url = try #require(url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "mailto")
        let items = components.queryItems ?? []
        #expect(Set(items.map(\.name)).isSubset(of: ["subject", "body"]), "no extra fields: \(items.map(\.name))")
        return (components.path, items.first { $0.name == "subject" }?.value, items.first { $0.name == "body" }?.value)
    }

    private func record(_ type: String, _ name: String, _ fields: [String: CKRecordValue]) -> CKRecord {
        let r = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name))
        for (k, v) in fields { r[k] = v }
        return r
    }

    @Test("A route report names the route, its record and its author")
    func routeReport() throws {
        let route = try #require(SharedRoute(record: record("SharedRoute", "route-123", [
            "name": "Lake loop" as CKRecordValue, "waypointsJSON": "[]" as CKRecordValue,
            "distanceMeters": 2400.0 as CKRecordValue, "authorName": "MistyOak" as CKRecordValue])))
        let mail = try decoded(CommunityReport(route: route).mailURL)
        #expect(mail.to == "support@wockett.app")
        #expect(mail.subject == "Wockett report: Route")
        let body = try #require(mail.body)
        #expect(body.contains("Record: route-123"))
        #expect(body.contains("Author: MistyOak"))
        #expect(body.contains("Content: Lake loop"))
        #expect(body.contains("Why I'm reporting it (optional):"))
    }

    @Test("A post report carries the badge and the message")
    func postReport() throws {
        let post = try #require(AchievementPost(record: record("WocketAchievement", "post-9", [
            "badgeName": "Trailblazer" as CKRecordValue, "badgeEmoji": "🥾" as CKRecordValue,
            "authorName": "SunnyFern" as CKRecordValue, "message": "Rude words here" as CKRecordValue])))
        let mail = try decoded(CommunityReport(post: post).mailURL)
        #expect(mail.subject == "Wockett report: Post")
        let body = try #require(mail.body)
        #expect(body.contains("Record: post-9"))
        #expect(body.contains("Author: SunnyFern"))
        #expect(body.contains("Content: 🥾 Trailblazer: Rude words here"))
    }

    @Test("A post with no message reports just the badge")
    func postReportNoMessage() throws {
        let post = try #require(AchievementPost(record: record("WocketAchievement", "post-10", [
            "badgeName": "Trailblazer" as CKRecordValue, "badgeEmoji": "🥾" as CKRecordValue,
            "authorName": "SunnyFern" as CKRecordValue])))
        let body = CommunityReport(post: post).body
        #expect(body.contains("Content: 🥾 Trailblazer\n"), "no dangling ': '")
    }

    @Test("A challenge report carries the emoji and the title")
    func challengeReport() throws {
        let challenge = try #require(WalkChallenge(record: record("Challenge", "chal-7", [
            "title": "10k a day" as CKRecordValue, "emoji": "🔥" as CKRecordValue,
            "startDate": Date() as CKRecordValue, "endDate": Date().addingTimeInterval(86_400) as CKRecordValue,
            "goalSteps": 10_000 as CKRecordValue, "authorName": "QuietPine" as CKRecordValue])))
        let mail = try decoded(CommunityReport(challenge: challenge).mailURL)
        #expect(mail.subject == "Wockett report: Challenge")
        let body = try #require(mail.body)
        #expect(body.contains("Record: chal-7"))
        #expect(body.contains("Author: QuietPine"))
        #expect(body.contains("Content: 🔥 10k a day"))
    }

    @Test("Text that means something in a URL stays text",
          arguments: ["a & b = c", "what? #tag 100%", "1+1", "line one\nline two", "Привет 東京 🐕", "x&body=injected"])
    func encodingRoundTrips(_ text: String) throws {
        let report = CommunityReport(kind: .post, recordID: CKRecord.ID(recordName: "r"), author: text, content: text)
        let mail = try decoded(report.mailURL)
        #expect(mail.body == report.body, "the body reads back exactly")
        #expect(mail.subject == report.subject)
    }

    @Test("A + stays a +, not a space, in mail apps that decode like a web form")
    func plusIsEncoded() throws {
        let report = CommunityReport(kind: .route, recordID: CKRecord.ID(recordName: "r"), author: "A", content: "A+B Loop")
        let url = try #require(report.mailURL).absoluteString
        #expect(url.contains("A%2BB"))
        #expect(!url.contains("+"))
    }

    // MARK: Hand-off order

    /// A moderation store on a throwaway settings suite, so tests never write
    /// into the app's own reported list.
    private func isolatedStore() -> CommunityModerationStore {
        let name = "CommunityReportTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return CommunityModerationStore(defaults: defaults)
    }

    private func freshReport() -> CommunityReport {
        CommunityReport(kind: .route, recordID: CKRecord.ID(recordName: "handoff-\(UUID().uuidString)"), author: "A", content: "B")
    }

    @Test("Hidden only once a mail app took the email, not before")
    func hiddenAfterHandoff() {
        let store = isolatedStore()
        let report = freshReport()
        var pending: ((Bool) -> Void)?
        var hidden: [CommunityReport] = []
        var fallbacks = 0
        CommunityReportHandoff.begin(report,
                                     open: { _, done in pending = done },
                                     hide: { CommunityReportHandoff.hide($0, store: store, onHide: { hidden.append($0) }) },
                                     showFallback: { _ in fallbacks += 1 })
        #expect(!store.isReported(report.recordID), "not remembered while Mail is opening")
        #expect(hidden.isEmpty)
        pending?(true)
        #expect(store.isReported(report.recordID))
        #expect(hidden == [report])
        #expect(fallbacks == 0)
    }

    @Test("With no mail app: the fallback shows and nothing is hidden yet")
    func fallbackWhenNoMail() {
        let store = isolatedStore()
        let report = freshReport()
        var hidden = 0
        var shown: CommunityReport?
        CommunityReportHandoff.begin(report,
                                     open: { _, done in done(false) },
                                     hide: { CommunityReportHandoff.hide($0, store: store, onHide: { _ in hidden += 1 }) },
                                     showFallback: { shown = $0 })
        #expect(shown == report)
        #expect(hidden == 0)
        #expect(!store.isReported(report.recordID), "hidden only when the alert closes")
    }

    @Test("Closing the fallback alert hides its item once; a second close does nothing")
    func alertClosedHidesOnce() {
        let store = isolatedStore()
        let report = freshReport()
        var unsent: CommunityReport? = report
        var hidden: [CommunityReport] = []
        let hide: (CommunityReport) -> Void = { CommunityReportHandoff.hide($0, store: store, onHide: { hidden.append($0) }) }
        CommunityReportHandoff.alertClosed(&unsent, hide: hide)
        #expect(unsent == nil)
        #expect(hidden == [report])
        #expect(store.isReported(report.recordID))
        CommunityReportHandoff.alertClosed(&unsent, hide: hide)
        #expect(hidden == [report], "closing again hides nothing more")
    }

    @Test("Closing with no alert up hides nothing")
    func alertClosedWithNothing() {
        var unsent: CommunityReport?
        var hidden = 0
        CommunityReportHandoff.alertClosed(&unsent) { _ in hidden += 1 }
        #expect(hidden == 0)
    }

    // MARK: Exact text

    @Test("The email body, line for line")
    func exactBody() {
        let report = CommunityReport(kind: .route, recordID: CKRecord.ID(recordName: "route-123"),
                                     author: "MistyOak", content: "Lake loop")
        #expect(report.body == """
            I'm reporting this route in Wockett's community.

            Kind: Route
            Record: route-123
            Author: MistyOak
            Content: Lake loop

            Why I'm reporting it (optional):

            """)
    }

    @Test("Copy Report holds exactly the address, the subject and the body")
    func exactClipboard() {
        let report = CommunityReport(kind: .challenge, recordID: CKRecord.ID(recordName: "c"), author: "A", content: "B")
        #expect(report.clipboardText == "To: support@wockett.app\nSubject: Wockett report: Challenge\n\n\(report.body)")
    }

    // MARK: Hub

    @Test("The hub stops showing a post reported elsewhere, without a reload")
    func hubFiltersReported() throws {
        let rec = record("WocketAchievement", "post-hub-\(UUID().uuidString)", [
            "badgeName": "Trailblazer" as CKRecordValue, "badgeEmoji": "🥾" as CKRecordValue])
        let post = try #require(AchievementPost(record: rec))
        let model = CommunityHubModel()
        model.moderation = isolatedStore()
        model.posts = [post]
        #expect(model.visiblePosts.map(\.id) == [post.id])
        model.moderation.report(post.id)
        #expect(model.visiblePosts.isEmpty)
    }

    private func challenge(_ name: String, author: String = "QuietPine") throws -> WalkChallenge {
        try #require(WalkChallenge(record: record("Challenge", name, [
            "title": "10k a day" as CKRecordValue, "startDate": Date() as CKRecordValue,
            "endDate": Date().addingTimeInterval(86_400) as CKRecordValue,
            "goalSteps": 10_000 as CKRecordValue, "authorName": author as CKRecordValue])))
    }

    @Test("The hub stops showing a challenge reported, or by an author blocked, elsewhere")
    func hubFiltersChallenges() throws {
        let reported = try challenge("chal-r-\(UUID().uuidString)")
        let blocked = try challenge("chal-b-\(UUID().uuidString)", author: "LoudCrow")
        let kept = try challenge("chal-k-\(UUID().uuidString)")
        let model = CommunityHubModel()
        model.moderation = isolatedStore()
        model.challenges = [reported, blocked, kept]
        #expect(model.visibleChallenges.count == 3)
        model.moderation.report(reported.id)
        model.moderation.block(author: "LoudCrow")
        #expect(model.visibleChallenges.map(\.id) == [kept.id])
    }

    @Test("Your challenge, once reported, leaves the hub with its standing")
    func hubHidesYourChallenge() throws {
        let mine = try challenge("chal-mine-\(UUID().uuidString)")
        let model = CommunityHubModel()
        model.moderation = isolatedStore()
        model.yourChallenge = mine
        model.standing = CommunityHubSummary.Standing(rank: 2, total: 5, aheadName: nil, gapToAhead: nil)
        #expect(model.visibleYourChallenge?.id == mine.id)
        #expect(model.visibleStanding != nil)
        model.moderation.report(mine.id)
        #expect(model.visibleYourChallenge == nil)
        #expect(model.visibleStanding == nil)
    }

    @Test("Reporting elsewhere tells a screen that reads the hub's lists to redraw")
    func reportIsObserved() throws {
        let rec = record("WocketAchievement", "post-obs-\(UUID().uuidString)", [
            "badgeName": "Trailblazer" as CKRecordValue, "badgeEmoji": "🥾" as CKRecordValue])
        let post = try #require(AchievementPost(record: rec))
        let model = CommunityHubModel()
        model.moderation = isolatedStore()
        model.posts = [post]
        var changed = false
        withObservationTracking { _ = model.visiblePosts } onChange: { changed = true }
        model.moderation.report(post.id)
        #expect(changed, "SwiftUI only redraws what Observation says changed")
    }

    @Test("The report says nothing about the reporter")
    func nothingAboutReporter() {
        let report = CommunityReport(kind: .route, recordID: CKRecord.ID(recordName: "r"), author: "A", content: "B")
        let text = report.body + report.subject
        #expect(!text.contains(CommunityNameService.shared.displayName))
        #expect(!text.contains(ChallengeService.shared.deviceID))
    }

    @Test("Send Feedback uses the same address")
    func feedbackAddress() throws {
        let mail = try decoded(SupportContact.mailURL(subject: "Wockett Feedback"))
        #expect(mail.to == "support@wockett.app")
        #expect(mail.subject == "Wockett Feedback")
        #expect(mail.body == nil)
    }
}
