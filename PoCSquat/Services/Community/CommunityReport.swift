import CloudKit
import CryptoKit
import SwiftUI
import UIKit

// MARK: - Support contact

/// The one support address: Settings → Send Feedback and community reports
/// both write to it.
enum SupportContact {
    static let email = "support@wockett.app"

    /// A `mailto:` URL. `URLComponents` encodes `&`, `=`, `#` and newlines
    /// inside the values, so user text can't break the URL into extra fields
    /// (checked in CommunityReportTests); building the string by hand can.
    static func mailURL(subject: String, body: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        var items = [URLQueryItem(name: "subject", value: subject)]
        if let body { items.append(URLQueryItem(name: "body", value: body)) }
        components.queryItems = items
        // `+` is left as is, and mail apps that decode the query like a web
        // form (Gmail) read it as a space: "A+B Loop" arrived as "A B Loop".
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

// MARK: - Community report

/// Why someone reports an item: the reasons the report sheet offers, in its
/// order. The raw value is what the `CommunityReport` record stores and the
/// staff dashboard reads, so it must not change.
enum CommunityReportReason: String, CaseIterable, Identifiable {
    case spam
    case offensive
    case unsafe
    case personalInfo
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spam:         return "Spam"
        case .offensive:    return "Offensive"
        case .unsafe:       return "Unsafe, or a place that shouldn't be shared"
        case .personalInfo: return "Shares someone's personal info"
        case .other:        return "Something else"
        }
    }
}

/// A report of one piece of community content. Since 2026-10-10 it is saved as
/// a `CommunityReport` record that only a Moderator can read (the staff
/// dashboard lists them); when that save fails it goes as an email the
/// reporter reviews and sends, as every report did before, so a report always
/// reaches the developer (App Review 1.2). Nothing about the reporter goes in:
/// only CloudKit's creator reference, or what their mail app adds.
struct CommunityReport: Equatable, Identifiable {
    enum Kind: String {
        case route = "Route"
        case post = "Post"
        case challenge = "Challenge"

        /// The record's `targetType`: what the dashboard reads.
        var targetType: String {
            switch self {
            case .route:     return "route"
            case .post:      return "post"
            case .challenge: return "challenge"
            }
        }
    }

    let kind: Kind
    let recordID: CKRecord.ID
    let author: String
    let content: String
    /// Chosen in the report sheet; nil until then.
    var reason: CommunityReportReason?
    /// The reporter's own words, optional, at most `CommunityReports.noteLimit`.
    var note = ""

    var id: String { recordID.recordName }

    init(route: SharedRoute) {
        self.init(kind: .route, recordID: route.id, author: route.authorName, content: route.name)
    }

    init(post: AchievementPost) {
        let message = post.message.isEmpty ? "" : ": \(post.message)"
        self.init(kind: .post, recordID: post.id, author: post.authorName,
                  content: "\(post.badgeEmoji) \(post.badgeName)\(message)")
    }

    init(challenge: WalkChallenge) {
        self.init(kind: .challenge, recordID: challenge.id, author: challenge.authorName,
                  content: "\(challenge.emoji) \(challenge.title)")
    }

    init(kind: Kind, recordID: CKRecord.ID, author: String, content: String) {
        self.kind = kind
        self.recordID = recordID
        self.author = author
        self.content = content
    }

    var subject: String { "Wockett report: \(kind.rawValue)" }

    /// The note as it is sent: trimmed, and cut to the limit.
    var trimmedNote: String {
        String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(CommunityReports.noteLimit))
    }

    var body: String {
        let reasonLine = reason.map { "Reason: \($0.title)\n" } ?? ""
        return """
        I'm reporting this \(kind.rawValue.lowercased()) in Wockett's community.

        Kind: \(kind.rawValue)
        Record: \(recordID.recordName)
        Author: \(author)
        Content: \(content)
        \(reasonLine)
        Why I'm reporting it (optional):
        \(trimmedNote)
        """
    }

    var mailURL: URL? { SupportContact.mailURL(subject: subject, body: body) }

    /// What "Copy Report" puts on the clipboard when no mail app can take it.
    var clipboardText: String { "To: \(SupportContact.email)\nSubject: \(subject)\n\n\(body)" }
}

// MARK: - Record

enum CommunityReports {
    static let recordType = "CommunityReport"
    /// The longest note a report keeps.
    static let noteLimit = 300
    /// The longest `targetSummary`: enough for a post's message and badge.
    static let summaryLimit = 500

    /// `report.<hash>`: the same for one reporter and one item on any of their
    /// devices, so CloudKit refuses a second report of it as already existing
    /// (votes work the same way). A hash, so the dashboard, which can read
    /// record names, can't read the reporter's iCloud ID out of one. With no
    /// known reporter (the lookup failed) every report gets its own name.
    static func recordName(target: String, reporter: String?) -> String {
        guard let reporter else { return "report.\(UUID().uuidString.lowercased())" }
        let digest = SHA256.hash(data: Data("\(target)\n\(reporter)".utf8))
        return "report." + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The record a report saves: what was reported and why, and nothing
    /// about who reported it (CloudKit adds the creator itself).
    static func record(for report: CommunityReport, reporter: String?) -> CKRecord {
        let target = report.recordID.recordName
        let record = CKRecord(recordType: recordType,
                              recordID: CKRecord.ID(recordName: recordName(target: target, reporter: reporter)))
        record["targetRecordName"] = target
        record["targetType"] = report.kind.targetType
        record["reason"] = (report.reason ?? .other).rawValue
        record["note"] = report.trimmedNote
        record["targetAuthorName"] = report.author
        record["targetSummary"] = String(report.content.prefix(summaryLimit))
        return record
    }

    enum Outcome: Equatable {
        case sent
        /// This person reported the item before, perhaps on another device.
        case alreadyReported
        /// Not saved: signed out, offline, timed out, or any other error. The
        /// sheet offers the email instead.
        case failed
    }

    /// CloudKit's answer to saving a report. A record name that already exists
    /// is this person's earlier report of the item. Anything else is a failure,
    /// including `permissionFailure`: a reporter can't write their own report,
    /// so a duplicate *might* come back that way, but so does a schema without
    /// the record type, and only the email is sure to reach us then.
    static func outcome(of error: Error) -> Outcome {
        (error as? CKError)?.code == .serverRecordChanged ? .alreadyReported : .failed
    }
}

// MARK: - Store seam

/// The CloudKit side, behind a protocol so the rules are tested without a
/// network or an iCloud account (CI has neither).
protocol CommunityReportStore: AnyObject {
    /// The iCloud user record name of whoever is signed in.
    func currentUserRecordName() async throws -> String
    /// Creates the record; throws CloudKit's error when it exists.
    func save(_ record: CKRecord) async throws
}

final class CloudKitCommunityReportStore: CommunityReportStore {
    private let container = CKContainer(identifier: WockettCloud.containerID)

    func currentUserRecordName() async throws -> String {
        try await container.userRecordID().recordName
    }

    func save(_ record: CKRecord) async throws {
        _ = try await container.publicCloudDatabase.save(record)
    }
}

/// Sending one report, kept out of the view so it can be tested.
@MainActor
enum CommunityReportSubmission {
    /// How long the sheet waits before offering the email instead. A save
    /// already sent when this passes may still land; the dashboard then
    /// shows the report and the email both. One not yet started is dropped.
    static let deadline: Duration = .seconds(15)

    /// `knownReporter` is the ID saved earlier (`MyAccount`), used when the
    /// lookup fails, so a slow or failed lookup doesn't skip the
    /// one-report-per-person rule.
    static func submit(_ report: CommunityReport,
                       store: CommunityReportStore,
                       knownReporter: @escaping () -> String? = { MyAccount.recordName },
                       deadline: Duration = deadline,
                       sleep: @escaping OptimisticVote.Sleep = { try await Task.sleep(for: $0) }) async -> CommunityReports.Outcome {
        do {
            let saved: Bool? = try await OptimisticVote.withDeadline(deadline, sleep: sleep) {
                // Unknown reporter: still try, and CloudKit says why it can't.
                let reporter = (try? await store.currentUserRecordName()) ?? knownReporter()
                // Past the deadline the sheet has offered the email: don't
                // also start a save that would land as a second report.
                try Task.checkCancellation()
                try await store.save(CommunityReports.record(for: report, reporter: reporter))
                return true
            }
            return saved == nil ? .failed : .sent
        } catch {
            return CommunityReports.outcome(of: error)
        }
    }
}

// MARK: - Flow

/// Where a report sheet is, kept out of the view so it can be tested.
struct CommunityReportFlow: Equatable {
    enum Phase: Equatable {
        /// Picking a reason; closing now reports nothing.
        case choosing
        case sending
        case sent
        case alreadyReported
        /// Not saved: the sheet offers the email.
        case failed
        /// A mail app took the email.
        case emailed
        /// No mail app took it: the sheet shows the address and Copy Report.
        case noMail
    }

    private(set) var phase: Phase = .choosing

    /// Closing the sheet now hides the item for the reporter: once a send was
    /// tried, whatever came of it, as when every report was an email.
    var hidesOnClose: Bool { phase != .choosing && phase != .sending }

    /// The sheet can't be swiped away mid-send: the answer would be lost.
    var canClose: Bool { phase != .sending }

    mutating func send() {
        guard phase == .choosing else { return }
        phase = .sending
    }

    mutating func finished(_ outcome: CommunityReports.Outcome) {
        guard phase == .sending else { return }
        switch outcome {
        case .sent:            phase = .sent
        case .alreadyReported: phase = .alreadyReported
        case .failed:          phase = .failed
        }
    }

    mutating func mailOpened(_ accepted: Bool) {
        guard phase == .failed || phase == .noMail else { return }
        phase = accepted ? .emailed : .noMail
    }
}

// MARK: - Hiding

/// Hiding a reported item happens in two steps, so it survives the app being
/// killed while the reporter is in Mail: remembered as soon as a send was
/// tried (`stepped`), removed from the screen once the sheet has closed
/// (`closed`), because removing it sooner takes the sheet's card with it.
enum CommunityReportHandoff {
    /// The sheet moved on. Once closing it would hide the item, remember the
    /// item as reported, so a relaunch keeps it hidden.
    static func stepped(_ report: CommunityReport, hides: Bool, store: CommunityModerationStore = .shared) {
        if hides { store.report(report.recordID) }
    }

    /// The sheet closed: remove the item from the screen if a send was tried,
    /// once. `closing` is what the sheet last said; cleared here.
    static func closed(_ closing: inout (report: CommunityReport, hide: Bool)?,
                       onHide: (CommunityReport) -> Void) {
        guard let last = closing else { return }
        closing = nil
        if last.hide { onHide(last.report) }
    }
}

// MARK: - Views

/// The Report item in a community context menu: one look everywhere, and
/// nothing at all on your own content (reporting it would only hide it from
/// you for good, and put it in the moderation queue).
struct CommunityReportButton: View {
    let title: String
    let author: CommunityAuthor
    var store: CommunityModerationStore = .shared
    let action: () -> Void

    init(_ title: String, author: CommunityAuthor, store: CommunityModerationStore = .shared,
         action: @escaping () -> Void) {
        self.title = title
        self.author = author
        self.store = store
        self.action = action
    }

    var body: some View {
        if store.canReport(author) {
            Button(role: .destructive, action: action) {
                Label {
                    Text(title)
                } icon: {
                    Image(wkt: .flagReport).wktIcon(.inline, tint: .red)
                }
            }
        }
    }
}

/// The Block item in a community context menu: one look everywhere, and
/// nothing at all on your own content.
struct CommunityBlockButton: View {
    let author: CommunityAuthor
    let onHide: () -> Void
    var store: CommunityModerationStore = .shared

    var body: some View {
        if !store.isMine(author) {
            Button(role: .destructive) {
                store.block(author)
                onHide()
            } label: {
                Label {
                    Text("Block \(author.name)")
                } icon: {
                    Image(wkt: .blockUser).wktIcon(.inline, tint: .red)
                }
            }
        }
    }
}

extension View {
    /// Asks why when `report` is set, sends the report, and offers the email
    /// if it can't be saved. The item is remembered and hidden (`onHide`) when
    /// the sheet closes after a send was tried; cancelling hides nothing.
    /// Attach it to a view that stays on screen while the sheet is up: the
    /// item is hidden only once the sheet has closed, so its own card works.
    func communityReporting(_ report: Binding<CommunityReport?>,
                            onHide: @escaping (CommunityReport) -> Void) -> some View {
        modifier(CommunityReportModifier(request: report, onHide: onHide))
    }
}

private struct CommunityReportModifier: ViewModifier {
    @Binding var request: CommunityReport?
    let onHide: (CommunityReport) -> Void
    /// What the sheet decided, read when it closes.
    @State private var closing: (report: CommunityReport, hide: Bool)?

    func body(content: Content) -> some View {
        content
            .sheet(item: $request, onDismiss: {
                CommunityReportHandoff.closed(&closing, onHide: onHide)
            }, content: { report in
                CommunityReportSheet(report: report) { sent, hide in
                    closing = (sent, hide)
                    CommunityReportHandoff.stepped(sent, hides: hide)
                }
            })
    }
}

/// The report sheet: why, an optional note, Send, then the answer. When the
/// report can't be saved it offers the email instead.
struct CommunityReportSheet: View {
    @State private var report: CommunityReport
    /// Told on every step: the report as it stands, and whether closing the
    /// sheet now hides its item. On every step, not only at Done, because a
    /// swipe down closes the sheet without Done.
    let onChange: (CommunityReport, Bool) -> Void
    var store: CommunityReportStore = CloudKitCommunityReportStore()

    @State private var flow = CommunityReportFlow()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @FocusState private var noteFocused: Bool

    init(report: CommunityReport, onChange: @escaping (CommunityReport, Bool) -> Void) {
        _report = State(initialValue: report)
        self.onChange = onChange
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                switch flow.phase {
                case .choosing, .sending: form
                case .sent: answer(.success, "Thanks. We'll review it.",
                                   "It's hidden for you now. Reports go to the Wockett team, without your name.")
                case .alreadyReported: answer(.success, "You've already reported this",
                                              "We have your report. It's hidden for you now.")
                case .emailed: answer(.success, "Thanks for letting us know",
                                      "Send the email to finish your report. It's hidden for you now.")
                case .failed, .noMail: fallback
                }
            }
            .navigationTitle("Report \(report.kind.rawValue)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled(!flow.canClose)
        .onChange(of: flow) { _, flow in onChange(report, flow.hidesOnClose) }
        .presentationDetents([.large])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("report.sheet")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch flow.phase {
        case .choosing:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { close() }.foregroundColor(.earthMuted)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") { send() }
                    .foregroundColor(.earthGreen)
                    .disabled(report.reason == nil)
            }
        case .sending:
            ToolbarItem(placement: .confirmationAction) { ProgressView() }
        default:
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { close() }.foregroundColor(.earthGreen)
            }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                VStack(alignment: .leading, spacing: 8) {
                    WktSectionHeader(title: "Why are you reporting it?")
                    ForEach(CommunityReportReason.allCases) { reason in
                        reasonRow(reason)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    WktSectionHeader(title: "Anything to add?")
                    TextField("Optional", text: $report.note, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.wktBodyText)
                        .foregroundColor(.earthCream)
                        .focused($noteFocused)
                        .onChange(of: report.note) { _, note in
                            if note.count > CommunityReports.noteLimit {
                                report.note = String(note.prefix(CommunityReports.noteLimit))
                            }
                        }
                        .wktCard()
                    Text("\(report.note.count) of \(CommunityReports.noteLimit) characters. Your name isn't sent with a report.")
                        .font(.wktLabel)
                        .foregroundColor(.earthMuted)
                }
            }
            .padding(.horizontal, WktSpacing.screen)
            .padding(.vertical, 24)
        }
        .disabled(flow.phase == .sending)
        .scrollDismissesKeyboard(.interactively)
    }

    private func reasonRow(_ reason: CommunityReportReason) -> some View {
        let selected = report.reason == reason
        return Button {
            report.reason = reason
        } label: {
            HStack(spacing: 12) {
                Text(reason.title)
                    .font(.wktRowTitle)
                    .foregroundColor(selected ? .white : .earthCream)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if selected {
                    Image(wkt: .check).wktIcon(.inline, tint: .white, onFill: true)
                }
            }
            .padding(WktSpacing.cardPadding)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .wktChoiceBackground(selected: selected)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.98))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func answer(_ symbol: WktSymbol, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 16) {
            WktIconBadge(symbol: symbol, size: 64)
            Text(title)
                .font(.wktCardTitle).foregroundColor(.earthCream)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.wktBodyText).foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
            Spacer()
            WktPrimaryButton(title: "Done") { close() }
        }
        .padding(.horizontal, WktSpacing.screen)
        .padding(.vertical, 24)
    }

    private var fallback: some View {
        VStack(spacing: 16) {
            WktIconBadge(symbol: .envelope, tint: .earthOrange, size: 64)
            Text("Couldn't send your report")
                .font(.wktCardTitle).foregroundColor(.earthCream)
                .multilineTextAlignment(.center)
            Text(flow.phase == .noMail
                 ? "Email \(SupportContact.email) to report this. Copy Report puts the details on your clipboard."
                 : "Email it to us instead, so it still reaches us. The details are filled in for you.")
                .font(.wktBodyText).foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
            Spacer()
            if flow.phase == .failed, let url = report.mailURL {
                WktPrimaryButton(title: "Email Report", symbol: .envelope) {
                    openURL(url) { accepted in flow.mailOpened(accepted) }
                }
            }
            WktSecondaryButton(title: "Copy Report") {
                UIPasteboard.general.string = report.clipboardText
            }
        }
        .padding(.horizontal, WktSpacing.screen)
        .padding(.vertical, 24)
    }

    private func send() {
        noteFocused = false
        flow.send()
        let report = report
        let store = store
        Task {
            flow.finished(await CommunityReportSubmission.submit(report, store: store))
        }
    }

    private func close() {
        dismiss()
    }
}
