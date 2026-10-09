import Foundation
import CloudKit
import Observation

// MARK: - Content Filter

struct ContentFilter {
    static let nameLengthLimit    = 60
    static let messageLengthLimit = 200

    enum ValidationError: LocalizedError {
        case tooLong(field: String, limit: Int)
        case containsProfanity

        var errorDescription: String? {
            switch self {
            case .tooLong(let field, let limit):
                return "\(field) must be \(limit) characters or fewer."
            case .containsProfanity:
                return "Content contains language that isn't allowed."
            }
        }
    }

    private static let blockedTerms: Set<String> = [
        "fuck", "shit", "bitch", "cunt", "bastard", "dick", "piss",
        "cock", "pussy", "whore", "slut", "nigger", "faggot", "retard", "asshole"
    ]

    static func validate(name: String? = nil, message: String? = nil) throws {
        if let name {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count > nameLengthLimit { throw ValidationError.tooLong(field: "Name", limit: nameLengthLimit) }
            if containsProfanity(t) { throw ValidationError.containsProfanity }
        }
        if let message {
            let t = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count > messageLengthLimit { throw ValidationError.tooLong(field: "Message", limit: messageLengthLimit) }
            if containsProfanity(t) { throw ValidationError.containsProfanity }
        }
    }

    private static func containsProfanity(_ text: String) -> Bool {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return words.contains { blockedTerms.contains($0) }
    }
}

// MARK: - Community author

/// Who is behind a piece of community content: the display name it shows,
/// and the iCloud account CloudKit stamps on it (`creatorUserRecordID`). The
/// name is text the posting phone writes, picked from 270 combinations, so two
/// people can share one and anyone can write any; the account can't be faked.
struct CommunityAuthor: Equatable {
    let name: String
    /// The creator's user record name; nil when CloudKit didn't say.
    let account: String?

    /// CloudKit gives your own records this creator.
    var isMe: Bool { account == CKCurrentUserDefaultName }

    init(name: String, account: String?) {
        self.name = name
        self.account = account
    }
}

// MARK: - Community Moderation Store

/// Observable, so a screen that filters with `shouldHide` (the Community hub's
/// cached lists) redraws when something is reported or blocked on another
/// screen: the lists live in UserDefaults, which Observation can't see, so
/// every change bumps `revision` and every read touches it.
@Observable
final class CommunityModerationStore {
    static let shared = CommunityModerationStore()

    @ObservationIgnored private let reportedKey = "communityReportedIds"
    /// Names blocked before 2026-10-09, and authors whose account is unknown.
    @ObservationIgnored private let blockedKey  = "communityBlockedAuthors"
    /// Accounts blocked since 2026-10-09.
    @ObservationIgnored private let blockedAccountsKey = "communityBlockedAccounts"
    private(set) var revision = 0

    @ObservationIgnored private let defaults: UserDefaults

    /// `defaults` is for tests, so they don't write into the app's own settings.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Report

    func isReported(_ id: CKRecord.ID) -> Bool {
        stored(forKey: reportedKey).contains(id.recordName)
    }

    func report(_ id: CKRecord.ID) {
        append(id.recordName, toKey: reportedKey)
    }

    // MARK: - Block author

    /// Blocked when the author's account is blocked, or their name is on the
    /// older list (blocks from before accounts, and authors with no account).
    func isBlocked(_ author: CommunityAuthor) -> Bool {
        if let account = author.account, !author.isMe,
           stored(forKey: blockedAccountsKey).contains(account) { return true }
        return stored(forKey: blockedKey).contains(author.name)
    }

    /// Blocks the author's account, so a name change doesn't get past it and a
    /// namesake isn't hidden. Only an author with no known account is blocked
    /// by name. Never blocks yourself.
    func block(_ author: CommunityAuthor) {
        guard !author.isMe else { return }
        if let account = author.account {
            append(account, toKey: blockedAccountsKey)
        } else {
            append(author.name, toKey: blockedKey)
        }
    }

    // MARK: - Convenience

    func shouldHide(id: CKRecord.ID, author: CommunityAuthor) -> Bool {
        isReported(id) || isBlocked(author)
    }

    // MARK: - Private

    private func stored(forKey key: String) -> [String] {
        _ = revision
        return defaults.stringArray(forKey: key) ?? []
    }

    private func append(_ value: String, toKey key: String) {
        var list = stored(forKey: key)
        guard !list.contains(value) else { return }
        list.append(value)
        defaults.set(list, forKey: key)
        revision += 1
    }
}
