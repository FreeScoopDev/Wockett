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
        "Mossy", "Amber", "Russet", "Dappled", "Sunlit", "Quiet", "Bright", "Breezy", "Cedar", "Clear",
        "Cozy", "Dewy", "Dusky", "Early", "Fern", "Frosty", "Glad", "Hazy", "Jolly", "Kind",
        "Leafy", "Lucky", "Mellow", "Merry", "Rainy", "Rosy", "Sandy", "Snowy", "Sunny", "Windy"
    ]
    static let nouns = [
        "Oak", "Heron", "Fern", "Cedar", "Maple", "Wolf", "Falcon", "Birch", "Stone", "River",
        "Meadow", "Pine", "Hawk", "Willow", "Aspen", "Moss", "Elk", "Sage", "Badger", "Brook",
        "Canyon", "Clover", "Comet", "Cove", "Creek", "Dune", "Finch", "Fox", "Glen", "Grove",
        "Hare", "Hill", "Lark", "Lynx", "Otter", "Owl", "Pebble", "Robin", "Trail", "Wren"
    ]

    /// Adjective + Noun + two digits: about 160,000 names.
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

    /// CloudKit's answer when the name's record already exists: someone holds it.
    static func isTaken(_ error: Error) -> Bool {
        (error as? CKError)?.code == .serverRecordChanged
    }
}

// MARK: - Store seam

/// The CloudKit side, behind a protocol so claiming is tested without a
/// network or an iCloud account (CI has neither).
protocol CommunityNameStore: AnyObject {
    /// The name this signed-in account already holds, if any (from another
    /// device, or an earlier install).
    func claimedName() async throws -> String?
    /// Creates the name's record; throws CloudKit's error when it exists.
    func claim(_ name: String) async throws
}

final class CloudKitCommunityNameStore: CommunityNameStore {
    private let container = CKContainer(identifier: WockettCloud.containerID)
    private var db: CKDatabase { container.publicCloudDatabase }

    func claimedName() async throws -> String? {
        let me = try await container.userRecordID()
        let query = CKQuery(recordType: CommunityNames.recordType,
                            predicate: NSPredicate(format: "creatorUserRecordID == %@",
                                                   CKRecord.Reference(recordID: me, action: .none)))
        let (results, _) = try await db.records(matching: query, desiredKeys: ["name"], resultsLimit: 1)
        return results.lazy.compactMap { try? $0.1.get()["name"] as? String }.first
    }

    func claim(_ name: String) async throws {
        let record = CKRecord(recordType: CommunityNames.recordType,
                              recordID: CKRecord.ID(recordName: CommunityNames.recordName(for: name)))
        record["name"] = name
        _ = try await db.save(record)
    }
}

// MARK: - Service

/// The name this account posts under, claimed before its first community write.
final class CommunityNameService {
    static let shared = CommunityNameService(store: CloudKitCommunityNameStore())

    enum NameError: LocalizedError {
        case noFreeName
        var errorDescription: String? {
            "Couldn't find a free community name. Check your connection and try again."
        }
    }

    /// The claimed name, remembered so later writes don't ask CloudKit again.
    static let claimedKey = "communityClaimedName"
    /// The name this phone used before names were claimed (and the fallback
    /// shown before a claim). Kept, and tried first, so an existing user keeps
    /// their name when it is free.
    static let localKey = "communityUsername"
    static let maxTries = 10

    private let store: CommunityNameStore
    private let defaults: UserDefaults
    private let makeName: () -> String

    init(store: CommunityNameStore, defaults: UserDefaults = .standard,
         makeName: @escaping () -> String = { CommunityNames.random() },
         notifications: NotificationCenter = .default) {
        self.store = store
        self.defaults = defaults
        self.makeName = makeName
        // A different iCloud account on this phone holds a different name.
        notifications.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forgetClaim() }
        }
    }

    /// The name to show: the claimed one, else the one this phone will try to
    /// claim first. Never asks CloudKit.
    var displayName: String {
        if let claimed = defaults.string(forKey: Self.claimedKey) { return claimed }
        if let local = defaults.string(forKey: Self.localKey) { return local }
        let generated = makeName()
        defaults.set(generated, forKey: Self.localKey)
        return generated
    }

    func forgetClaim() {
        defaults.removeObject(forKey: Self.claimedKey)
    }

    /// The name this account holds, claiming one if it holds none. Throws when
    /// CloudKit can't be reached, or no free name turned up: then nothing
    /// should be posted.
    func claimedName() async throws -> String {
        if let claimed = defaults.string(forKey: Self.claimedKey) { return claimed }
        if let existing = try await store.claimedName() {
            remember(existing)
            return existing
        }
        var candidate = displayName                 // keep the name this phone already shows, if free
        for _ in 0..<Self.maxTries {
            do {
                try await store.claim(candidate)
                remember(candidate)
                return candidate
            } catch where CommunityNames.isTaken(error) {
                candidate = makeName()
            }
        }
        throw NameError.noFreeName
    }

    private func remember(_ name: String) {
        defaults.set(name, forKey: Self.claimedKey)
        defaults.set(name, forKey: Self.localKey)
    }
}
