import CloudKit
import Foundation
import os

// MARK: - Blocks that follow you
//
// Audit 2026-10-12, finding 15: blocks lived only in this phone's
// UserDefaults, so after a reinstall, or on a second device, everyone you
// blocked was back. They are now one record in your **private** CloudKit
// database (only you can read it), merged with this phone's copy.
//
// Not NSUbiquitousKeyValueStore: the app has no
// `com.apple.developer.ubiquity-kvstore-identifier` entitlement, and CloudKit
// is already set up.
//
// Merging is a union of people, newest change wins per person. An unblock is
// kept as an entry (`blocked == false`) rather than removed, so an older block
// on another device can't bring the person back through the union.

/// One person on the block list, or someone unblocked since.
struct BlockEntry: Codable, Equatable {
    var blocked: Bool
    var changedAt: Date
    /// The name they showed when blocked, for the Blocked people screen.
    /// Nil for blocks from before names were kept.
    var label: String?
}

/// Every block and unblock, keyed by `account:<user record name>` or
/// `name:<display name>`, the two ways the app has ever blocked someone.
struct BlockList: Codable, Equatable {
    var entries: [String: BlockEntry] = [:]

    static let accountPrefix = "account:"
    static let namePrefix = "name:"

    static func key(account: String) -> String { accountPrefix + account }
    static func key(name: String) -> String { namePrefix + name }

    /// When blocks migrated from UserDefaults are stamped: before any real
    /// change, so an unblock made anywhere beats them.
    static let legacyStamp = Date(timeIntervalSince1970: 0)

    func isBlocked(_ key: String) -> Bool { entries[key]?.blocked == true }

    /// Keys currently blocked, sorted for a stable order.
    var blockedKeys: [String] { entries.filter { $0.value.blocked }.map(\.key).sorted() }

    mutating func set(_ key: String, blocked: Bool, at date: Date, label: String? = nil) {
        entries[key] = BlockEntry(blocked: blocked, changedAt: date, label: label ?? entries[key]?.label)
    }

    /// Both lists together: every person on either (the union), and for a
    /// person on both, the newer change. On a tie the block wins: hiding
    /// someone by mistake is better than showing someone blocked.
    static func merge(_ a: BlockList, _ b: BlockList) -> BlockList {
        var out = a
        for (key, theirs) in b.entries {
            guard let ours = out.entries[key] else { out.entries[key] = theirs; continue }
            var winner: BlockEntry
            if theirs.changedAt != ours.changedAt {
                winner = theirs.changedAt > ours.changedAt ? theirs : ours
            } else {
                winner = theirs.blocked ? theirs : ours
            }
            winner.label = winner.label ?? ours.label ?? theirs.label
            out.entries[key] = winner
        }
        return out
    }

    /// Blocks kept in UserDefaults before 2026-10-13, as entries.
    static func legacy(accounts: [String], names: [String]) -> BlockList {
        var list = BlockList()
        for account in accounts { list.set(key(account: account), blocked: true, at: legacyStamp) }
        for name in names { list.set(key(name: name), blocked: true, at: legacyStamp, label: name) }
        return list
    }

    func encoded() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decoded(_ text: String?) -> BlockList? {
        guard let data = text?.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(BlockList.self, from: data)
    }
}

// MARK: - Store seam

/// The private-database side, behind a protocol so syncing is tested
/// without iCloud.
protocol BlockListBackend: AnyObject {
    /// The stored list, or nil when none is stored yet.
    func fetch() async throws -> BlockList?
    /// Saves `list` over the copy last fetched. Throws `BlockListConflict`
    /// carrying the server's copy when another device saved in between.
    func save(_ list: BlockList) async throws
}

struct BlockListConflict: Error {
    let server: BlockList
}

final class CloudKitBlockListBackend: BlockListBackend {
    static let recordType = "CommunityBlockList"
    static let recordName = "communityBlocks"

    private var database: CKDatabase { CKContainer(identifier: WockettCloud.containerID).privateCloudDatabase }
    private var recordID: CKRecord.ID { CKRecord.ID(recordName: Self.recordName) }
    /// The record last fetched or saved, so a save carries its change tag and
    /// CloudKit refuses it if another device saved first.
    private var last: CKRecord?

    func fetch() async throws -> BlockList? {
        do {
            let record = try await database.record(for: recordID)
            last = record
            return BlockList.decoded(record["entries"] as? String) ?? BlockList()
        } catch let error as CKError where error.code == .unknownItem {
            last = nil
            return nil
        }
    }

    func save(_ list: BlockList) async throws {
        let record = last ?? CKRecord(recordType: Self.recordType, recordID: recordID)
        record["entries"] = list.encoded()
        do {
            last = try await database.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            let server = error.serverRecord
            last = server
            throw BlockListConflict(server: BlockList.decoded(server?["entries"] as? String) ?? BlockList())
        }
    }
}

// MARK: - Sync

/// Keeps this phone's block list and the private-database copy the same.
@MainActor
final class BlockListSync {
    static let shared = BlockListSync(backend: CloudKitBlockListBackend(), moderation: .shared)

    static let maxTries = 3

    private let backend: BlockListBackend
    private let moderation: CommunityModerationStore
    private let log = Logger(subsystem: "com.wockett.app", category: "BlockListSync")
    private var running: Task<Bool, Never>?
    private var again = false
    private var started = false

    init(backend: BlockListBackend, moderation: CommunityModerationStore) {
        self.backend = backend
        self.moderation = moderation
    }

    /// Starts syncing on every block and unblock, and when the iCloud
    /// account changes (the new account's list comes in).
    func start(notifications: NotificationCenter = .default) {
        moderation.onBlocksChanged = { [weak self] in self?.sync() }
        guard !started else { return }
        started = true
        notifications.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.sync() }
        }
    }

    /// Syncs now, or once more after the sync already running. Returns the
    /// task, for tests to await; true when the server copy matches this phone's.
    @discardableResult
    func sync() -> Task<Bool, Never> {
        if let running {
            again = true
            return running
        }
        // Holds the sync until the round ends: a sync is short, and one
        // dropped halfway would leave the server copy behind.
        let task = Task { () -> Bool in
            var ok = await self.runOnce()
            while self.again {
                self.again = false
                ok = await self.runOnce()
            }
            self.running = nil
            return ok
        }
        running = task
        return task
    }

    /// One round: fetch, merge, keep the merge here, save it if the server
    /// lacks it. A lost race merges the winner's copy in and tries again.
    /// Any failure leaves this phone's list as it is.
    private func runOnce() async -> Bool {
        do {
            var server = try await backend.fetch()
            for _ in 0..<Self.maxTries {
                let merged = BlockList.merge(moderation.blockList, server ?? BlockList())
                moderation.replaceBlockList(merged)
                if merged == server { return true }
                do {
                    try await backend.save(merged)
                    return true
                } catch let conflict as BlockListConflict {
                    server = conflict.server
                }
            }
            log.error("Block list sync gave up after \(Self.maxTries) conflicts")
            return false
        } catch {
            log.error("Block list sync failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
