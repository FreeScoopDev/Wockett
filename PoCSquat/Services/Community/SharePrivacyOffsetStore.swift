import Foundation
import CloudKit

/// Where the user's `SharePrivacyOffset` is kept.
@MainActor
protocol SharePrivacyOffsetBackend {
    /// The stored offset, or nil when none has been stored. Throws when it
    /// can't tell (no iCloud account, offline): that is never "none".
    func fetch() async throws -> SharePrivacyOffset?
    /// Stores `offset` unless another device stored one first, and returns
    /// whichever is stored.
    func create(_ offset: SharePrivacyOffset) async throws -> SharePrivacyOffset
}

/// The user's one `SharePrivacyOffset`. It must be the same on every device:
/// two devices with different offsets would publish zones with two different
/// centres, and those together point back at home. So it is made only when
/// iCloud says none is stored, and never as a stand-in on this device when
/// iCloud can't be reached; then `current()` throws and nothing is shared.
@MainActor
final class SharePrivacyOffsetStore {
    static let shared = SharePrivacyOffsetStore(backend: CloudKitSharePrivacyOffsetBackend())

    struct Unavailable: Error {}

    private let backend: SharePrivacyOffsetBackend
    private var cached: SharePrivacyOffset?

    /// `notifications` is for tests, so the system's `.CKAccountChanged` on
    /// `.default` can't reach a store under test.
    init(backend: SharePrivacyOffsetBackend, notifications: NotificationCenter = .default) {
        self.backend = backend
        // Another iCloud account has another offset: never carry this one over.
        notifications.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget() }
        }
    }

    /// Drops the cached offset, so the next `current()` asks iCloud again.
    func forget() {
        cached = nil
    }

    func current() async throws -> SharePrivacyOffset {
        if let cached { return cached }
        let offset: SharePrivacyOffset
        if let stored = try await backend.fetch() {
            offset = stored
        } else {
            offset = try await backend.create(.random())
        }
        guard offset.isValid else { throw Unavailable() }
        cached = offset
        return offset
    }

    /// The offset, or nil when it isn't available now.
    func currentIfAvailable() async -> SharePrivacyOffset? {
        try? await current()
    }
}

/// One record in the user's private CloudKit database, at a fixed name so
/// every device reads the same one. Only the user can read it.
struct CloudKitSharePrivacyOffsetBackend: SharePrivacyOffsetBackend {
    static let recordType = "SharePrivacyOffset"
    static let recordName = "sharePrivacyOffset"

    private var database: CKDatabase { CKContainer(identifier: WockettCloud.containerID).privateCloudDatabase }
    private var recordID: CKRecord.ID { CKRecord.ID(recordName: Self.recordName) }

    func fetch() async throws -> SharePrivacyOffset? {
        do {
            return Self.offset(from: try await database.record(for: recordID))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func create(_ offset: SharePrivacyOffset) async throws -> SharePrivacyOffset {
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["east"] = offset.east
        record["north"] = offset.north
        record["extra"] = offset.extra
        do {
            return Self.offset(from: try await database.save(record)) ?? offset
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Another device stored one first: use that one.
            if let server = error.serverRecord, let stored = Self.offset(from: server) { return stored }
            guard let stored = try await fetch() else { throw error }
            return stored
        }
    }

    static func offset(from record: CKRecord) -> SharePrivacyOffset? {
        guard let east = record["east"] as? Double, let north = record["north"] as? Double,
              let extra = record["extra"] as? Double else { return nil }
        let offset = SharePrivacyOffset(east: east, north: north, extra: extra)
        return offset.isValid ? offset : nil
    }
}
