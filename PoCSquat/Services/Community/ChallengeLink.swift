import Foundation
import Observation

// MARK: - ChallengeLink
//
// A challenge's web link: https://wockett.app/c/?id=<recordName>. With Wockett
// installed iOS hands it to the app (universal link, docs/.well-known); without
// it, docs/c/index.html shows the challenge's name and a Get Wockett button.
// The page checks the id with the same rule as `recordName(from:)`; change one,
// change the other.
//
// The id is a query item, not a path segment, because GitHub Pages serves
// files only: /c/<id> would have to be the site-wide 404 page.

enum ChallengeLink {
    static let host = "wockett.app"
    static let path = "/c/"
    /// CloudKit names a challenge with a UUID; this leaves room without letting
    /// anything else through.
    static let maxIDLength = 100

    static func url(for recordName: String) -> URL? {
        guard isValid(recordName) else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = path
        parts.queryItems = [URLQueryItem(name: "id", value: recordName)]
        return parts.url
    }

    /// The challenge a link names, or nil when the URL is anything other than
    /// a well-formed challenge link. Everything in it is untrusted input.
    static func recordName(from url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == host,
              parts.path == path || parts.path == "/c",
              let items = parts.queryItems,
              items.filter({ $0.name == "id" }).count == 1,
              let id = items.first(where: { $0.name == "id" })?.value,
              isValid(id)
        else { return nil }
        return id
    }

    static func isValid(_ recordName: String) -> Bool {
        (1...maxIDLength).contains(recordName.count)
            && recordName.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
}

// MARK: - ChallengeLinkInbox
//
// Where an opened challenge link waits until the app can act on it. A link
// that launches the app arrives before the root view exists, so the App reads
// this from `.task` at launch as well as from `onChange` (the notification-tap
// race in CLAUDE.md).

@MainActor
@Observable
final class ChallengeLinkInbox {
    static let shared = ChallengeLinkInbox()

    private(set) var pending: String?

    /// Holds the link's challenge. False, and nothing held, for any other URL.
    @discardableResult
    func post(_ url: URL) -> Bool {
        guard let recordName = ChallengeLink.recordName(from: url) else { return false }
        pending = recordName
        return true
    }

    func consume() -> String? {
        defer { pending = nil }
        return pending
    }
}
