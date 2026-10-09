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

// MARK: - Community Moderation Store

/// Observable, so a screen that filters with `shouldHide` (the Community hub's
/// cached lists) redraws when something is reported or blocked on another
/// screen: the lists live in UserDefaults, which Observation can't see, so
/// every change bumps `revision` and every read touches it.
@Observable
final class CommunityModerationStore {
    static let shared = CommunityModerationStore()

    @ObservationIgnored private let reportedKey = "communityReportedIds"
    @ObservationIgnored private let blockedKey  = "communityBlockedAuthors"
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

    func isBlocked(author: String) -> Bool {
        stored(forKey: blockedKey).contains(author)
    }

    func block(author: String) {
        append(author, toKey: blockedKey)
    }

    // MARK: - Convenience

    func shouldHide(id: CKRecord.ID, author: String) -> Bool {
        isReported(id) || isBlocked(author: author)
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
