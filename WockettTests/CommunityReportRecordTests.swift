import Testing
import CloudKit
import Foundation
@testable import PoCSquat

/// A report saved as a `CommunityReport` record (2026-10-10): what the record
/// holds, the one-report-per-person rule, and the email fallback when CloudKit
/// can't take it. The staff dashboard reads these fields by name.
@MainActor
struct CommunityReportRecordTests {

    private func report(_ kind: CommunityReport.Kind = .post, target: String = "post-9",
                        content: String = "🥾 Trailblazer: hello") -> CommunityReport {
        var r = CommunityReport(kind: kind, recordID: CKRecord.ID(recordName: target), author: "SunnyFern", content: content)
        r.reason = .offensive
        r.note = "Rude"
        return r
    }

    /// CloudKit without a network: records what was saved, throws what it is told to.
    private final class FakeStore: CommunityReportStore {
        var user: Result<String, Error> = .success("_reporter1")
        var saveError: Error?
        var hangs = false
        /// The lookup takes a moment (and ignores cancellation, like CloudKit).
        var userDelay = false
        var saved: [CKRecord] = []

        func currentUserRecordName() async throws -> String {
            if userDelay {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { c.resume() }
                }
            }
            return try user.get()
        }

        func save(_ record: CKRecord) async throws {
            if hangs { try await Task.sleep(for: .seconds(600)) }
            if let saveError { throw saveError }
            saved.append(record)
        }
    }

    // MARK: Record

    @Test("The record holds what was reported, why, and the note")
    func recordFields() {
        let record = CommunityReports.record(for: report(), reporter: "_reporter1")
        #expect(record.recordType == "CommunityReport")
        #expect(record["targetRecordName"] as? String == "post-9")
        #expect(record["targetType"] as? String == "post")
        #expect(record["reason"] as? String == "offensive")
        #expect(record["note"] as? String == "Rude")
        #expect(record["targetAuthorName"] as? String == "SunnyFern")
        #expect(record["targetSummary"] as? String == "🥾 Trailblazer: hello")
        #expect(Set(record.allKeys()) == ["targetRecordName", "targetType", "reason", "note",
                                          "targetAuthorName", "targetSummary"],
                "nothing about the reporter: CloudKit adds the creator itself")
    }

    @Test("Each kind names its type the way the dashboard reads it", arguments: [
        (CommunityReport.Kind.route, "route"), (.post, "post"), (.challenge, "challenge")])
    func targetTypes(kind: CommunityReport.Kind, expected: String) {
        #expect(CommunityReports.record(for: report(kind), reporter: nil)["targetType"] as? String == expected)
    }

    @Test("The record holds the reason chosen", arguments: CommunityReportReason.allCases)
    func recordReason(reason: CommunityReportReason) {
        var r = report()
        r.reason = reason
        #expect(CommunityReports.record(for: r, reporter: nil)["reason"] as? String == reason.rawValue)
    }

    @Test("A report with no reason is filed as other")
    func noReasonIsOther() {
        var r = report()
        r.reason = nil
        #expect(CommunityReports.record(for: r, reporter: nil)["reason"] as? String == "other")
    }

    @Test("Reason raw values are the ones the dashboard knows")
    func reasonValues() {
        #expect(CommunityReportReason.allCases.map(\.rawValue) == ["spam", "offensive", "unsafe", "personalInfo", "other"])
    }

    @Test("The note is trimmed and kept to 300 characters; the summary to 500")
    func caps() {
        var r = report(content: String(repeating: "c", count: 900))
        r.note = "  " + String(repeating: "n", count: 400) + "\n"
        let record = CommunityReports.record(for: r, reporter: nil)
        #expect((record["note"] as? String) == String(repeating: "n", count: 300))
        #expect((record["targetSummary"] as? String)?.count == 500)
    }

    // MARK: One report per person

    @Test("One reporter and one item always make the same record name")
    func sameName() {
        let a = CommunityReports.recordName(target: "post-9", reporter: "_reporter1")
        #expect(a == CommunityReports.recordName(target: "post-9", reporter: "_reporter1"))
        #expect(a != CommunityReports.recordName(target: "post-9", reporter: "_reporter2"))
        #expect(a != CommunityReports.recordName(target: "post-10", reporter: "_reporter1"))
        #expect(a.hasPrefix("report."))
        #expect(!a.contains("_reporter1"), "the dashboard can read names; it must not read the reporter")
    }

    @Test("With no known reporter, each report gets its own name")
    func unknownReporter() {
        #expect(CommunityReports.recordName(target: "t", reporter: nil)
                != CommunityReports.recordName(target: "t", reporter: nil))
    }

    // MARK: Outcomes

    @Test("An existing record name means already reported")
    func duplicate() {
        #expect(CommunityReports.outcome(of: CKError(.serverRecordChanged)) == .alreadyReported)
    }

    @Test("Every other error falls back to the email", arguments: [
        CKError.Code.notAuthenticated, .networkUnavailable, .networkFailure, .permissionFailure,
        .unknownItem, .quotaExceeded, .serviceUnavailable])
    func failures(code: CKError.Code) {
        #expect(CommunityReports.outcome(of: CKError(code)) == .failed)
    }

    @Test("A non-CloudKit error falls back to the email")
    func otherError() {
        #expect(CommunityReports.outcome(of: URLError(.timedOut)) == .failed)
    }

    // MARK: Submit

    @Test("A saved report is sent, under the reporter's record name")
    func submitSaves() async throws {
        let store = FakeStore()
        let r = report()
        #expect(await CommunityReportSubmission.submit(r, store: store) == .sent)
        let saved = try #require(store.saved.first)
        #expect(saved.recordID.recordName == CommunityReports.recordName(target: "post-9", reporter: "_reporter1"))
    }

    @Test("A second report of the same item is already reported, not a failure")
    func submitDuplicate() async {
        let store = FakeStore()
        store.saveError = CKError(.serverRecordChanged)
        #expect(await CommunityReportSubmission.submit(report(), store: store) == .alreadyReported)
    }

    @Test("Offline or signed out: failed, so the sheet offers the email")
    func submitFails() async {
        let store = FakeStore()
        store.saveError = CKError(.notAuthenticated)
        #expect(await CommunityReportSubmission.submit(report(), store: store) == .failed)
        store.saveError = CKError(.networkUnavailable)
        #expect(await CommunityReportSubmission.submit(report(), store: store) == .failed)
    }

    @Test("When the reporter can't be looked up, the report is still tried")
    func submitWithoutReporter() async throws {
        let store = FakeStore()
        store.user = .failure(CKError(.networkFailure))
        #expect(await CommunityReportSubmission.submit(report(), store: store, knownReporter: { nil }) == .sent)
        #expect(store.saved.count == 1)
    }

    @Test("When the lookup fails, the saved ID keeps one report per person")
    func submitUsesKnownReporter() async throws {
        let store = FakeStore()
        store.user = .failure(CKError(.networkFailure))
        #expect(await CommunityReportSubmission.submit(report(), store: store, knownReporter: { "_saved" }) == .sent)
        let saved = try #require(store.saved.first)
        #expect(saved.recordID.recordName == CommunityReports.recordName(target: "post-9", reporter: "_saved"))
    }

    @Test("A save that doesn't answer by the deadline is failed")
    func submitTimesOut() async {
        let store = FakeStore()
        store.hangs = true
        let outcome = await CommunityReportSubmission.submit(report(), store: store, deadline: .seconds(15),
                                                             sleep: { _ in })
        #expect(outcome == .failed)
    }

    @Test("By default the sheet waits 15 seconds before offering the email")
    func defaultDeadline() async {
        let store = FakeStore()
        store.hangs = true
        var waited: Duration?
        _ = await CommunityReportSubmission.submit(report(), store: store, sleep: { waited = $0 })
        #expect(waited == .seconds(15))
    }

    @Test("Past the deadline, a save not yet started is dropped")
    func noSaveAfterDeadline() async {
        let store = FakeStore()
        store.userDelay = true
        let outcome = await CommunityReportSubmission.submit(report(), store: store, sleep: { _ in })
        #expect(outcome == .failed)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(store.saved.isEmpty, "the email was offered; a late record would be a second report")
    }

    // MARK: Flow

    @Test("Cancelling before Send hides nothing")
    func cancelHidesNothing() {
        let flow = CommunityReportFlow()
        #expect(!flow.hidesOnClose)
        #expect(flow.canClose)
    }

    @Test("Mid-send the sheet can't close; each answer shows its own screen and hides the item", arguments: [
        (CommunityReports.Outcome.sent, CommunityReportFlow.Phase.sent),
        (.alreadyReported, .alreadyReported), (.failed, .failed)])
    func sendThenHide(outcome: CommunityReports.Outcome, expected: CommunityReportFlow.Phase) {
        var flow = CommunityReportFlow()
        flow.send()
        #expect(!flow.canClose)
        #expect(!flow.hidesOnClose)
        flow.finished(outcome)
        #expect(flow.phase == expected)
        #expect(flow.canClose)
        #expect(flow.hidesOnClose)
        flow.send()
        #expect(flow.phase == expected, "Send again does nothing once answered")
    }

    @Test("A failed save offers the email; with no mail app, the address and Copy Report")
    func fallbackPhases() {
        var flow = CommunityReportFlow()
        flow.send()
        flow.finished(.failed)
        #expect(flow.phase == .failed)
        flow.mailOpened(false)
        #expect(flow.phase == .noMail)
        #expect(flow.hidesOnClose)
        var taken = CommunityReportFlow()
        taken.send()
        taken.finished(.failed)
        taken.mailOpened(true)
        #expect(taken.phase == .emailed)
        #expect(taken.hidesOnClose)
    }

    @Test("A sent report never turns into an email")
    func sentStaysSent() {
        var flow = CommunityReportFlow()
        flow.send()
        flow.finished(.sent)
        flow.mailOpened(false)
        flow.finished(.failed)
        #expect(flow.phase == .sent)
    }

    // MARK: Email fallback

    @Test("The fallback email carries the reason and the note")
    func emailHasReason() {
        var r = report()
        r.note = "  Rude \n"
        let body = r.body
        #expect(body.contains("Reason: Offensive"))
        #expect(body.hasSuffix("Why I'm reporting it (optional):\nRude"))
    }
}
