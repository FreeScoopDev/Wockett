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

    /// CloudKit gives your own records this creator while you're signed in.
    /// Signed out, it gives your real user record name instead, so ask the
    /// moderation store (`isMine`), which also knows that name.
    var isDefaultOwner: Bool { account == CKCurrentUserDefaultName }

    /// The account behind a record: its CloudKit creator, unless a test passes
    /// one. Read in one place for every community type.
    static func account(of record: CKRecord, creator: CKRecord.ID? = nil) -> String? {
        (creator ?? record.creatorUserRecordID)?.recordName
    }

    init(name: String, account: String?) {
        self.name = name
        self.account = account
    }
}

/// This phone's own iCloud user record name, saved while signed in, so your
/// content is recognised as yours when CloudKit later gives its real creator
/// (signed out). Local only. Not tied to the main actor: it only reads and
/// writes one UserDefaults value, which is safe from anywhere.
nonisolated enum MyAccount {
    static let key = "wkt_myUserRecordName"

    static var recordName: String? { UserDefaults.standard.string(forKey: key) }

    static func refresh() async {
        if let id = try? await CKContainer(identifier: WockettCloud.containerID).userRecordID() {
            UserDefaults.standard.set(id.recordName, forKey: key)
        }
    }

    /// Forgets the saved ID: the iCloud account changed, and the old one's
    /// content must not count as yours.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Community content that Report and Block can hide.
protocol CommunityModerated {
    var id: CKRecord.ID { get }
    var author: CommunityAuthor { get }
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
    /// Suspended accounts as last fetched (SuspensionService), JSON. Held so
    /// a load offline still hides them.
    @ObservationIgnored private let suspensionsKey = "communitySuspensions"
    private(set) var revision = 0

    @ObservationIgnored private let defaults: UserDefaults

    /// Your own account's record name, if known (a seam for tests).
    @ObservationIgnored private let myAccount: () -> String?

    @ObservationIgnored private let accountChangeWork: () async -> Void

    /// `defaults`, `myAccount`, `notifications` and `onAccountChange` are for
    /// tests, so they don't touch the app's own settings or iCloud.
    init(defaults: UserDefaults = .standard,
         myAccount: @escaping () -> String? = { MyAccount.recordName },
         notifications: NotificationCenter = .default,
         onAccountChange: @escaping () async -> Void = { MyAccount.clear(); await MyAccount.refresh() }) {
        self.defaults = defaults
        self.myAccount = myAccount
        self.accountChangeWork = onAccountChange
        // A different iCloud account on this phone: the saved own ID belongs to
        // the old one. Forget it, look the new one up, and redraw anything that
        // decided "yours" with the old one.
        notifications.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.accountChanged() }   // Xcode 26.6 can't infer this closure's type otherwise
        }
    }

    /// Returns the save of the new ID, for tests to await.
    @discardableResult
    func accountChanged() -> Task<Void, Never> {
        revision += 1
        let work = accountChangeWork
        return Task { [weak self] in
            await work()
            self?.revision += 1
        }
    }

    /// Your own content: never blockable, never hidden by a block.
    func isMine(_ author: CommunityAuthor) -> Bool {
        author.isDefaultOwner || (author.account != nil && author.account == myAccount())
    }

    // MARK: - Report

    func isReported(_ id: CKRecord.ID) -> Bool {
        stored(forKey: reportedKey).contains(id.recordName)
    }

    /// Report is offered on everyone's content but your own.
    func canReport(_ author: CommunityAuthor) -> Bool {
        !isMine(author)
    }

    func report(_ id: CKRecord.ID) {
        append(id.recordName, toKey: reportedKey)
    }

    // MARK: - Block author

    /// Blocked when the author's account is blocked, or their name is on the
    /// older list (blocks from before accounts, and authors with no account).
    func isBlocked(_ author: CommunityAuthor) -> Bool {
        // Never your own content: an old name block can match your own name
        // (Block used to be offered on your own posts, and namesakes are common).
        guard !isMine(author) else { return false }
        if let account = author.account, stored(forKey: blockedAccountsKey).contains(account) { return true }
        return stored(forKey: blockedKey).contains(author.name)
    }

    /// Blocks the author's account, so a name change doesn't get past it and a
    /// namesake isn't hidden. Only an author with no known account is blocked
    /// by name. Never blocks yourself.
    func block(_ author: CommunityAuthor) {
        guard !isMine(author) else { return }
        if let account = author.account {
            append(account, toKey: blockedAccountsKey)
        } else {
            append(author.name, toKey: blockedKey)
        }
    }

    // MARK: - Suspensions

    /// Decoded once, not per item a list filters.
    @ObservationIgnored private var decodedSuspensions: [Suspension]?

    /// The suspensions held, ended ones included (each is checked against the time).
    var suspensions: [Suspension] {
        _ = revision
        if let decodedSuspensions { return decodedSuspensions }
        let list = defaults.data(forKey: suspensionsKey)
            .flatMap { try? JSONDecoder().decode([Suspension].self, from: $0) } ?? []
        decodedSuspensions = list
        return list
    }

    /// Replaces the list held; redraws only when it changed.
    func setSuspensions(_ list: [Suspension]) {
        guard list != suspensions, let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: suspensionsKey)
        decodedSuspensions = list
        revision += 1
    }

    /// Whether this phone knows its own account yet.
    var knowsMyAccount: Bool { myAccount() != nil }

    /// The suspension on `account` in force at `now`, if any.
    func activeSuspension(for account: String?, at now: Date) -> Suspension? {
        guard let account else { return nil }
        return suspensions.first { $0.account == account && $0.isActive(at: now) }
    }

    /// Hidden because its author is suspended. Never your own content.
    func isSuspended(_ author: CommunityAuthor, at now: Date = Date()) -> Bool {
        guard !isMine(author) else { return false }
        return activeSuspension(for: author.account, at: now) != nil
    }

    /// Your own account's suspension in force at `now`; nil when there is
    /// none or your account isn't known yet.
    func mySuspension(at now: Date) -> Suspension? {
        activeSuspension(for: myAccount(), at: now)
    }

    // MARK: - Convenience

    func shouldHide(id: CKRecord.ID, author: CommunityAuthor) -> Bool {
        isReported(id) || isBlocked(author) || isSuspended(author)
    }

    /// `items` minus anything reported or blocked: the one filter every list uses.
    func visible<Item: CommunityModerated>(_ items: [Item]) -> [Item] {
        items.filter { !shouldHide(id: $0.id, author: $0.author) }
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
