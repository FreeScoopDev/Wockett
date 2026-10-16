import Testing
import CloudKit
import Foundation
@testable import PoCSquat

/// A report saved as a `CommunityReport` record (2026-10-10): what the record
/// holds, its random name (2026-10-16), one report per item from this phone,
/// and the email fallback when CloudKit can't take it. The staff dashboard
/// reads these fields by name.
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
        var saveError: Error?
        var hangs = false
        var saved: [CKRecord] = []

        func save(_ record: CKRecord) async throws {
            if hangs { try await Task.sleep(for: .seconds(600)) }
            if let saveError { throw saveError }
            saved.append(record)
        }
    }

    private func ledger() -> CommunityReportLedger {
        let name = "CommunityReportRecordTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name) ?? .standard
        d.removePersistentDomain(forName: name)
        return CommunityReportLedger(defaults: d)
    }

    // MARK: Record

    @Test("The record holds what was reported, why, and the note")
    func recordFields() {
        let record = CommunityReports.record(for: report())
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
        #expect(CommunityReports.record(for: report(kind))["targetType"] as? String == expected)
    }

    @Test("The record holds the reason chosen", arguments: CommunityReportReason.allCases)
    func recordReason(reason: CommunityReportReason) {
        var r = report()
        r.reason = reason
        #expect(CommunityReports.record(for: r)["reason"] as? String == reason.rawValue)
    }

    @Test("A report with no reason is filed as other")
    func noReasonIsOther() {
        var r = report()
        r.reason = nil
        #expect(CommunityReports.record(for: r)["reason"] as? String == "other")
    }

    @Test("Reason raw values are the ones the dashboard knows")
    func reasonValues() {
        #expect(CommunityReportReason.allCases.map(\.rawValue) == ["spam", "offensive", "unsafe", "personalInfo", "other"])
    }

    @Test("The note is trimmed and kept to 300 characters; the summary to 500")
    func caps() {
        var r = report(content: String(repeating: "c", count: 900))
        r.note = "  " + String(repeating: "n", count: 400) + "\n"
        let record = CommunityReports.record(for: r)
        #expect((record["note"] as? String) == String(repeating: "n", count: 300))
        #expect((record["targetSummary"] as? String)?.count == 500)
    }

    // MARK: Record name

    @Test("Every report gets its own random name: nothing in it can be computed from the item or the account")
    func randomName() throws {
        let a = CommunityReports.record(for: report()).recordID.recordName
        let b = CommunityReports.record(for: report()).recordID.recordName
        #expect(a != b, "the same item reported twice must not share a name")
        #expect(a.hasPrefix("report."))
        let uuid = String(a.dropFirst("report.".count))
        #expect(UUID(uuidString: uuid) != nil, "report.<UUID>")
        #expect(uuid == uuid.lowercased())
        #expect(!a.contains("post-9"))
    }

    // MARK: Outcomes

    @Test("Every save error falls back to the email, a name clash included", arguments: [
        CKError.Code.serverRecordChanged, .notAuthenticated, .networkUnavailable, .networkFailure, .permissionFailure,
        .unknownItem, .quotaExceeded, .serviceUnavailable])
    func failures(code: CKError.Code) async {
        let store = FakeStore()
        store.saveError = CKError(code)
        #expect(await CommunityReportSubmission.submit(report(), store: store, ledger: ledger()) == .failed)
    }

    @Test("A non-CloudKit error falls back to the email")
    func otherError() async {
        let store = FakeStore()
        store.saveError = URLError(.timedOut)
        #expect(await CommunityReportSubmission.submit(report(), store: store, ledger: ledger()) == .failed)
    }

    // MARK: Submit

    @Test("A saved report is sent, with the report's fields")
    func submitSaves() async throws {
        let store = FakeStore()
        #expect(await CommunityReportSubmission.submit(report(), store: store, ledger: ledger()) == .sent)
        let saved = try #require(store.saved.first)
        #expect(saved.recordID.recordName.hasPrefix("report."))
        #expect(saved["targetRecordName"] as? String == "post-9")
        #expect(saved["reason"] as? String == "offensive")
    }

    @Test("A second report of the same item from this phone is already reported, and saves nothing")
    func submitDuplicate() async {
        let store = FakeStore()
        let book = ledger()
        #expect(await CommunityReportSubmission.submit(report(), store: store, ledger: book) == .sent)
        #expect(await CommunityReportSubmission.submit(report(), store: store, ledger: book) == .alreadyReported)
        #expect(store.saved.count == 1)
        #expect(await CommunityReportSubmission.submit(report(target: "post-10"), store: store, ledger: book) == .sent,
                "another item is a new report")
        #expect(store.saved.count == 2)
    }

    @Test("A report that wasn't saved is not remembered, so reporting again sends it")
    func failureNotRemembered() async {
        let store = FakeStore()
        let book = ledger()
        store.saveError = CKError(.networkUnavailable)
        #expect(await CommunityReportSubmission.submit(report(), store: store, ledger: book) == .failed)
        store.saveError = nil
        #expect(await CommunityReportSubmission.submit(report(), store: store, ledger: book) == .sent)
        #expect(store.saved.count == 1)
    }

    @Test("A report that timed out is not remembered")
    func timeoutNotRemembered() async {
        let store = FakeStore()
        let book = ledger()
        store.hangs = true
        #expect(await CommunityReportSubmission.submit(report(), store: store, ledger: book, sleep: { _ in }) == .failed)
        #expect(!book.contains(CommunityReportLedger.reportEntry(target: "post-9")))
    }

    @Test("Offline or signed out: failed, so the sheet offers the email")
    func submitFails() async {
        let store = FakeStore()
        store.saveError = CKError(.notAuthenticated)
        #expect(await CommunityReportSubmission.submit(report(), store: store, ledger: ledger()) == .failed)
        store.saveError = CKError(.networkUnavailable)
        #expect(await CommunityReportSubmission.submit(report(), store: store, ledger: ledger()) == .failed)
    }

    @Test("A save that doesn't answer by the deadline is failed")
    func submitTimesOut() async {
        let store = FakeStore()
        store.hangs = true
        let outcome = await CommunityReportSubmission.submit(report(), store: store, ledger: ledger(),
                                                             deadline: .seconds(15), sleep: { _ in })
        #expect(outcome == .failed)
    }

    @Test("By default the sheet waits 15 seconds before offering the email")
    func defaultDeadline() async {
        let store = FakeStore()
        store.hangs = true
        var waited: Duration?
        _ = await CommunityReportSubmission.submit(report(), store: store, ledger: ledger(), sleep: { waited = $0 })
        #expect(waited == .seconds(15))
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
