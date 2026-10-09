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

/// A report of one piece of community content, sent to support as an email
/// the reporter reviews and sends. App Review 1.2 wants reports to reach the
/// developer; Joe removes reported records in the CloudKit Console. Nothing
/// about the reporter goes in: only what their mail app adds.
struct CommunityReport: Equatable {
    enum Kind: String {
        case route = "Route"
        case post = "Post"
        case challenge = "Challenge"
    }

    let kind: Kind
    let recordID: CKRecord.ID
    let author: String
    let content: String

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

    var body: String {
        """
        I'm reporting this \(kind.rawValue.lowercased()) in Wockett's community.

        Kind: \(kind.rawValue)
        Record: \(recordID.recordName)
        Author: \(author)
        Content: \(content)

        Why I'm reporting it (optional):

        """
    }

    var mailURL: URL? { SupportContact.mailURL(subject: subject, body: body) }

    /// What "Copy Report" puts on the clipboard when no mail app can take it.
    var clipboardText: String { "To: \(SupportContact.email)\nSubject: \(subject)\n\n\(body)" }
}

// MARK: - Report action

// MARK: - Handoff

/// The order a report goes in, kept out of the view so it can be tested: the
/// item is hidden (remembered across launches, and removed from the list) only
/// once a mail app took the email, or once the reporter closed the fallback
/// alert. Hiding sooner removes the card that shows the alert, and a list
/// refresh would drop it mid-alert (critic, 2026-10-09).
enum CommunityReportHandoff {
    static func begin(_ report: CommunityReport,
                      open: (URL, @escaping (Bool) -> Void) -> Void,
                      hide: @escaping (CommunityReport) -> Void,
                      showFallback: @escaping (CommunityReport) -> Void) {
        guard let url = report.mailURL else { showFallback(report); return }
        open(url) { accepted in
            if accepted { hide(report) } else { showFallback(report) }
        }
    }

    /// Hides `report`'s item: remembered, so it stays hidden after a relaunch,
    /// then removed from the screen.
    static func hide(_ report: CommunityReport, store: CommunityModerationStore = .shared, onHide: () -> Void) {
        store.report(report.recordID)
        onHide()
    }
}

extension View {
    /// Sends `report` when it is set: remembers it locally (the reporter no
    /// longer sees the item, across launches), opens the email, and hides the
    /// item once a mail app took it. With no mail app it shows the address and
    /// a Copy Report button, and hides the item when that alert closes. The
    /// card stays on screen until then, because a card that removes itself
    /// can no longer show the alert.
    func communityReporting(_ report: Binding<CommunityReport?>, onHide: (() -> Void)?) -> some View {
        modifier(CommunityReportModifier(request: report, onHide: onHide ?? {}))
    }
}

extension View {
    /// A Report menu on its own, for rows that have no menu of their own
    /// (the Community hub's posts and top routes).
    func communityReportMenu(_ title: String, report: @escaping () -> CommunityReport, onHide: @escaping () -> Void) -> some View {
        modifier(CommunityReportMenuModifier(title: title, makeReport: report, onHide: onHide))
    }
}

private struct CommunityReportMenuModifier: ViewModifier {
    let title: String
    let makeReport: () -> CommunityReport
    let onHide: () -> Void
    @State private var request: CommunityReport?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(role: .destructive) {
                    request = makeReport()
                } label: {
                    Label {
                        Text(title)
                    } icon: {
                        Image(wkt: .flagReport).wktIcon(.inline, tint: .red)
                    }
                }
            }
            .communityReporting($request, onHide: onHide)
    }
}

private struct CommunityReportModifier: ViewModifier {
    @Binding var request: CommunityReport?
    let onHide: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var unsent: CommunityReport?

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, report in
                guard let report else { return }
                request = nil
                CommunityReportHandoff.begin(report,
                                             open: { url, done in openURL(url, completion: done) },
                                             hide: { CommunityReportHandoff.hide($0, onHide: onHide) },
                                             showFallback: { unsent = $0 })
            }
            .alert("Couldn't open Mail",
                   isPresented: Binding(get: { unsent != nil },
                                        set: { shown in
                                            guard !shown, let report = unsent else { return }
                                            unsent = nil
                                            CommunityReportHandoff.hide(report, onHide: onHide)
                                        }),
                   presenting: unsent) { report in
                Button("Copy Report") { UIPasteboard.general.string = report.clipboardText }
                Button("OK", role: .cancel) {}
            } message: { _ in
                Text("Email \(SupportContact.email) to report this. Copy Report puts the details on your clipboard.")
            }
    }
}
