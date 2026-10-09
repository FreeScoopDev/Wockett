import CloudKit
import Foundation

// MARK: - Community names
//
// Community display names are random and anonymous (MistyOak42), and since
// 2026-10-09 no two accounts hold the same one. A name is held by a
// `CommunityName` record in the public database whose record name is
// `name.<lowercased name>`: CloudKit refuses a second record with the same
// name, so the first account to claim a name keeps it, exactly as one vote
// per person works (CommunityVotes.swift). The record holds only the name;
// CloudKit records which account created it, the same anonymous per-app ID
// every post already carries. Nobody types a name.
//
// Production needs the `CommunityName` type (field `name`, default grants)
// and a QUERYABLE index on `___createdBy` before a build with this ships.

enum CommunityNames {
    static let recordType = "CommunityName"

    /// Calm, neutral words: nothing that reads badly next to any other.
    static let adjectives = [
        "Misty", "Golden", "Ancient", "Silent", "Swift", "Wild", "Calm", "Wandering", "Gentle", "Humble",
        "Mossy", "Amber", "Russet", "Dappled", "Sunlit", "Quiet", "Bright", "Breezy", "Silver", "Clear",
        "Cozy", "Dewy", "Dusky", "Early", "Velvet", "Frosty", "Glad", "Hazy", "Jolly", "Kind",
        "Leafy", "Lucky", "Mellow", "Merry", "Rainy", "Rosy", "Sandy", "Snowy", "Sunny", "Windy"
    ]
    static let nouns = [
        "Oak", "Heron", "Fern", "Cedar", "Maple", "Wolf", "Falcon", "Birch", "Stone", "River",
        "Meadow", "Pine", "Hawk", "Willow", "Aspen", "Moss", "Elk", "Sage", "Badger", "Brook",
        "Canyon", "Clover", "Comet", "Cove", "Creek", "Dune", "Finch", "Fox", "Glen", "Grove",
        "Hare", "Hill", "Lark", "Lynx", "Otter", "Owl", "Pebble", "Robin", "Trail", "Wren"
    ]

    /// Adjective + Noun + two digits: 40 × 40 × 90 = 144,000 names.
    static func random<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let adjective = adjectives.randomElement(using: &generator) ?? "Misty"
        let noun = nouns.randomElement(using: &generator) ?? "Oak"
        return "\(adjective)\(noun)\(Int.random(in: 10...99, using: &generator))"
    }

    static func random() -> String {
        var g = SystemRandomNumberGenerator()
        return random(using: &g)
    }

    /// The claim's record name: one per name, whatever its letter case.
    static func recordName(for name: String) -> String { "name.\(name.lowercased())" }

}

// MARK: - Store seam

/// The CloudKit side, behind a protocol so claiming is tested without a
/// network or an iCloud account (CI has neither).
protocol CommunityNameStore: AnyObject {
    /// The signed-in account's user record name.
    func currentUser() async throws -> String
    /// The oldest name this signed-in account holds, if any (from another
    /// device, or an earlier install).
    func claimedName() async throws -> String?
    /// Creates the name's record. Throws if it can't, for whatever reason;
    /// the caller asks `owner(of:)` whose it is rather than reading the error.
    func claim(_ name: String) async throws
    /// Who created the name's record: nil when nobody holds the name.
    /// CloudKit names your own records' creator `CKCurrentUserDefaultName`.
    func owner(of name: String) async throws -> String?
}

final class CloudKitCommunityNameStore: CommunityNameStore {
    private let container = CKContainer(identifier: WockettCloud.containerID)
    private var db: CKDatabase { container.publicCloudDatabase }

    func currentUser() async throws -> String {
        try await container.userRecordID().recordName
    }

    func claimedName() async throws -> String? {
        let me = try await container.userRecordID()
        let query = CKQuery(recordType: CommunityNames.recordType,
                            predicate: NSPredicate(format: "creatorUserRecordID == %@",
                                                   CKRecord.Reference(recordID: me, action: .none)))
        // Oldest first, so every device settles on the same name if an account
        // ever held two.
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let (results, _) = try await db.records(matching: query, desiredKeys: ["name"], resultsLimit: 1)
        return results.lazy.compactMap { try? $0.1.get()["name"] as? String }.first
    }

    func claim(_ name: String) async throws {
        let record = CKRecord(recordType: CommunityNames.recordType,
                              recordID: CKRecord.ID(recordName: CommunityNames.recordName(for: name)))
        record["name"] = name
        _ = try await db.save(record)
    }

    func owner(of name: String) async throws -> String? {
        do {
            let record = try await db.record(for: CKRecord.ID(recordName: CommunityNames.recordName(for: name)))
            return record.creatorUserRecordID?.recordName ?? ""
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }
}

// MARK: - Service

/// The name this account posts under, claimed before its first community write.
@MainActor
@Observable
final class CommunityNameService {
    static let shared = CommunityNameService(store: CloudKitCommunityNameStore())

    enum NameError: LocalizedError {
        case noFreeName
        var errorDescription: String? {
            "Couldn't find a free community name. Check your connection and try again."
        }
    }

    /// The claimed name, and the account it belongs to: a claim is reused only
    /// by that account, so a phone signed into a different iCloud account
    /// (even while Wockett wasn't running) never posts under the old name.
    static let claimedKey = "communityClaimedName"
    static let claimedOwnerKey = "communityClaimedNameOwner"
    /// The name this phone used before names were claimed (and the one shown
    /// before a claim). Tried first, so an existing user keeps a free name.
    static let localKey = "communityUsername"
    static let maxTries = 10

    @ObservationIgnored private let store: CommunityNameStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeName: () -> String
    /// One claim at a time: two writes at once share it instead of each
    /// claiming a different name.
    @ObservationIgnored private var inFlight: Task<String, Error>?
    /// Bumped on every change, so labels showing `displayName` redraw.
    private(set) var revision = 0

    init(store: CommunityNameStore, defaults: UserDefaults = .standard,
         makeName: @escaping () -> String = { CommunityNames.random() },
         notifications: NotificationCenter = .default) {
        self.store = store
        self.defaults = defaults
        self.makeName = makeName
        // Fast path for a switch while running; the owner check covers the rest.
        notifications.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forgetClaim() }
        }
    }

    /// The name to show: the claimed one, else the one this phone will try to
    /// claim first. Never asks CloudKit; `refreshDisplayName` checks it.
    var displayName: String {
        _ = revision
        if let claimed = defaults.string(forKey: Self.claimedKey) { return claimed }
        if let local = defaults.string(forKey: Self.localKey) { return local }
        let generated = makeName()
        defaults.set(generated, forKey: Self.localKey)
        return generated
    }

    func forgetClaim() {
        defaults.removeObject(forKey: Self.claimedKey)
        defaults.removeObject(forKey: Self.claimedOwnerKey)
        revision += 1
    }

    /// Makes `displayName` the name a post would go out under, without
    /// claiming anything: the account's existing name if it has one, and a
    /// fresh local name if the one shown belongs to someone else. For screens
    /// that say "Posting as".
    func refreshDisplayName() async {
        guard let me = try? await store.currentUser() else { return }
        if defaults.string(forKey: Self.claimedOwnerKey) == me { return }
        if let existing = try? await store.claimedName() {
            remember(existing, owner: me)
            return
        }
        let local = displayName
        if let owner = try? await store.owner(of: local), !isMine(owner, me: me) {
            defaults.set(makeName(), forKey: Self.localKey)
            revision += 1
        }
    }

    /// The name this account holds, claiming one if it holds none. Throws when
    /// CloudKit can't be reached, or no free name turned up: then nothing
    /// should be posted.
    func claimedName() async throws -> String {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await resolveName() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func resolveName() async throws -> String {
        let me = try await store.currentUser()
        if defaults.string(forKey: Self.claimedOwnerKey) == me,
           let claimed = defaults.string(forKey: Self.claimedKey) { return claimed }
        if let existing = try await store.claimedName() {
            remember(existing, owner: me)
            return existing
        }
        var candidate = displayName                 // keep the name this phone already shows, if free
        for _ in 0..<Self.maxTries {
            do {
                try await store.claim(candidate)
                remember(candidate, owner: me)
                return candidate
            } catch {
                // Don't trust the error code: ask whose the name is. Ours (a
                // save that went through but whose answer was lost, or another
                // of our devices) means keep it; someone else's means try
                // another; nobody's means the failure was something else.
                guard let owner = try await store.owner(of: candidate) else { throw error }
                if isMine(owner, me: me) {
                    remember(candidate, owner: me)
                    return candidate
                }
                candidate = makeName()
            }
        }
        throw NameError.noFreeName
    }

    private func isMine(_ owner: String, me: String) -> Bool {
        owner == me || owner == CKCurrentUserDefaultName
    }

    private func remember(_ name: String, owner: String) {
        defaults.set(name, forKey: Self.claimedKey)
        defaults.set(owner, forKey: Self.claimedOwnerKey)
        defaults.set(name, forKey: Self.localKey)
        revision += 1
    }
}
