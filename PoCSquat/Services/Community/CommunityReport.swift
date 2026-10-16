import CloudKit
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

    /// `report.<random UUID>`, a new one for every report. Until 2026-10-16 it
    /// was a hash of the item and the reporter's account, both public (the
    /// account is the creator of everything they share), so anyone could
    /// compute it and learn from CloudKit refusing a save under it that the
    /// account had reported the item. One report per person is now kept by
    /// the phone (`CommunityReportLedger`) and by the staff dashboard, which
    /// counts each reporter once per item.
    static func recordName() -> String {
        "report.\(UUID().uuidString.lowercased())"
    }

    /// The record a report saves: what was reported and why, and nothing
    /// about who reported it (CloudKit adds the creator itself).
    static func record(for report: CommunityReport) -> CKRecord {
        let target = report.recordID.recordName
        let record = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: recordName()))
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
        /// This phone sent a report of the item before and CloudKit took it.
        case alreadyReported
        /// Not saved: signed out, offline, timed out, or any other error. The
        /// sheet offers the email instead. Every save error is this: a random
        /// name can't collide with an earlier report.
        case failed
    }
}

/// What this phone has had CloudKit accept: a report of an item, or a
/// challenge owner's request to delete on one day. Asked before saving, so a
/// second report from the same phone answers "already reported" without a
/// second record, as CloudKit's refusal of the old computed names did. Kept
/// in UserDefaults, on this device only: another device, or a reinstall, can
/// send again, and the staff dashboard counts that person once.
struct CommunityReportLedger {
    static let key = "communityReportsSent_v1"
    var defaults: UserDefaults = .standard

    static func reportEntry(target: String) -> String { "report:\(target)" }
    static func requestEntry(challenge: String, day: String) -> String { "request:\(challenge)@\(day)" }

    func contains(_ entry: String) -> Bool {
        defaults.stringArray(forKey: Self.key)?.contains(entry) ?? false
    }

    func record(_ entry: String) {
        var list = defaults.stringArray(forKey: Self.key) ?? []
        guard !list.contains(entry) else { return }
        list.append(entry)
        defaults.set(list, forKey: Self.key)
    }
}

// MARK: - Store seam

/// The CloudKit side, behind a protocol so the rules are tested without a
/// network or an iCloud account (CI has neither).
protocol CommunityReportStore: AnyObject {
    /// Creates the record; throws CloudKit's error when it can't.
    func save(_ record: CKRecord) async throws
}

final class CloudKitCommunityReportStore: CommunityReportStore {
    private let container = CKContainer(identifier: WockettCloud.containerID)

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

    /// An item this phone already reported (`ledger`) is answered without a
    /// save; it is recorded there only once CloudKit has taken the report.
    static func submit(_ report: CommunityReport,
                       store: CommunityReportStore,
                       ledger: CommunityReportLedger = CommunityReportLedger(),
                       deadline: Duration = deadline,
                       sleep: @escaping OptimisticVote.Sleep = { try await Task.sleep(for: $0) }) async -> CommunityReports.Outcome {
        let entry = CommunityReportLedger.reportEntry(target: report.recordID.recordName)
        if ledger.contains(entry) { return .alreadyReported }
        do {
            // Nothing is awaited before the save any more (the account lookup
            // that named the record is gone), so there is no window in which
            // the deadline can pass before the save starts.
            let saved: Bool? = try await OptimisticVote.withDeadline(deadline, sleep: sleep) {
                try await store.save(CommunityReports.record(for: report))
                return true
            }
            guard saved != nil else { return .failed }
            ledger.record(entry)
            return .sent
        } catch {
            return .failed
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

/// Hiding a reported item, without taking the sheet down with it. The item
/// is remembered (and so filtered out of every list) only once the sheet has
/// closed, or when the app goes to the background with the sheet up: a list
/// refresh that filters it out while the sheet is open would remove the card
/// hosting the sheet, and the email fallback with it (critic, 2026-10-10).
/// The background step keeps it hidden if the app is killed while the
/// reporter is in Mail.
enum CommunityReportHandoff {
    /// The app is leaving the foreground (or a send answered while it was
    /// away): remember the item if closing the sheet would hide it.
    static func backgrounded(_ closing: (report: CommunityReport, hide: Bool)?,
                             store: CommunityModerationStore = .shared) {
        guard let closing, closing.hide else { return }
        store.report(closing.report.recordID)
    }

    /// The sheet closed: if a send was tried, remember the item and remove it
    /// from the screen, once. `closing` is what the sheet last said; cleared here.
    static func closed(_ closing: inout (report: CommunityReport, hide: Bool)?,
                       store: CommunityModerationStore = .shared,
                       onHide: (CommunityReport) -> Void) {
        guard let last = closing else { return }
        closing = nil
        guard last.hide else { return }
        store.report(last.report.recordID)
        onHide(last.report)
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
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .sheet(item: $request, onDismiss: {
                CommunityReportHandoff.closed(&closing, onHide: onHide)
            }, content: { report in
                CommunityReportSheet(report: report) { sent, hide in
                    closing = (sent, hide)
                    // A send that answers while the app is away: remember now,
                    // no phase change follows before a kill.
                    if scenePhase != .active { CommunityReportHandoff.backgrounded(closing) }
                }
            })
            .onChange(of: scenePhase) { _, phase in
                // Not only .background: a kill from the app switcher can come
                // straight from .inactive. No card-hosted list reacts to the
                // store, so remembering early takes no sheet down.
                if phase != .active { CommunityReportHandoff.backgrounded(closing) }
            }
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
        WktResultView(symbol: symbol, title: title, detail: detail) { close() }
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
