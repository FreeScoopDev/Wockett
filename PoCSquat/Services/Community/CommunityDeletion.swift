import CloudKit
import SwiftUI

// MARK: - Deleting your own community content
//
// Your own shared routes, feed posts and challenge entries can be deleted
// from the app (Scoops Dev LLC liability review, 2026-10-11), rather than by
// emailing support. "Yours" is `CommunityModerationStore.isMine`: the
// record's creator is your user record, the same rule that hides Report and
// Block on your own items. CloudKit's `_creator` WRITE grant (schema.ckdb),
// which covers delete, is what lets the creator, and only the creator,
// remove a record; Moderator can too.

/// One item someone asked to delete.
struct CommunityDeletionRequest: Identifiable, Equatable {
    enum Kind: Equatable {
        case route
        case post
        /// Your leaderboard entry in a challenge (`challengeKey` its record name).
        case entry(challengeKey: String)
    }

    let kind: Kind
    let recordID: CKRecord.ID

    var id: String { recordID.recordName }
}

enum CommunityDeletion {
    static let confirmTitle = "Delete from Community?"
    static let confirmMessage = "This removes it for everyone. Routes other people already saved stay with them."
    static let buttonTitle = "Delete from Community"

    enum Outcome: Equatable {
        case deleted
        case failed(String)
    }

    /// What a delete came to. A record already gone was deleted.
    static func outcome(of error: Error?) -> Outcome {
        guard let error else { return .deleted }
        switch (error as? CKError)?.code {
        case .unknownItem?:
            return .deleted
        case .notAuthenticated?:
            return .failed("Sign in to iCloud in the Settings app to delete it.")
        case .permissionFailure?:
            return .failed("Only the account that shared it can delete it.")
        default:
            return .failed("Couldn't delete it. Check your connection and try again.")
        }
    }

    /// Clears what this phone remembers about the item once it's gone: a
    /// route is no longer one you published (its Wocketts stop counting),
    /// and an entry's challenge is no longer one you joined.
    static func forget(_ request: CommunityDeletionRequest, defaults: UserDefaults = .standard) {
        switch request.kind {
        case .route:
            let key = CommunityRouteService.publishedKey
            let ids = (defaults.stringArray(forKey: key) ?? []).filter { $0 != request.recordID.recordName }
            defaults.set(ids, forKey: key)
        case .entry(let challengeKey):
            let key = ChallengeService.joinedKey
            var joined = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
            joined[challengeKey] = nil
            defaults.set(joined, forKey: key)
        case .post:
            break
        }
    }
}

// MARK: - Store seam

/// The CloudKit side, behind a protocol so the rules are tested without a
/// network or an iCloud account.
protocol CommunityRecordDeleter: AnyObject {
    func delete(_ id: CKRecord.ID) async throws
}

final class CloudKitCommunityRecordDeleter: CommunityRecordDeleter {
    private let db = CKContainer(identifier: WockettCloud.containerID).publicCloudDatabase

    func delete(_ id: CKRecord.ID) async throws {
        _ = try await db.deleteRecord(withID: id)
    }
}

@MainActor
enum CommunityDeletionRun {
    /// Deletes the one record, then, if it's gone, clears the bookkeeping.
    static func run(_ request: CommunityDeletionRequest,
                    deleter: CommunityRecordDeleter = CloudKitCommunityRecordDeleter(),
                    defaults: UserDefaults = .standard) async -> CommunityDeletion.Outcome {
        var failure: Error?
        do { try await deleter.delete(request.recordID) } catch { failure = error }
        let outcome = CommunityDeletion.outcome(of: failure)
        if outcome == .deleted { CommunityDeletion.forget(request, defaults: defaults) }
        return outcome
    }
}

// MARK: - Views

/// "Delete from Community" in a long-press menu: only on your own content.
struct CommunityDeleteButton: View {
    let author: CommunityAuthor
    var store: CommunityModerationStore = .shared
    let action: () -> Void

    var body: some View {
        if store.isMine(author) {
            Button(role: .destructive, action: action) {
                Label {
                    Text(CommunityDeletion.buttonTitle)
                } icon: {
                    Image(wkt: .discard).wktIcon(.inline, tint: .red)
                }
            }
        }
    }
}

extension View {
    /// Asks before deleting `request`'s item ("Delete from Community?"),
    /// deletes it, and calls `onDeleted` once it's gone; a failure says why
    /// and leaves the item.
    func communityDeleting(_ request: Binding<CommunityDeletionRequest?>,
                           onDeleted: @escaping (CommunityDeletionRequest) -> Void) -> some View {
        modifier(CommunityDeletionModifier(request: request, onDeleted: onDeleted))
    }
}

private struct CommunityDeletionModifier: ViewModifier {
    @Binding var request: CommunityDeletionRequest?
    let onDeleted: (CommunityDeletionRequest) -> Void
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .alert(CommunityDeletion.confirmTitle,
                   isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                   presenting: request) { pending in
                Button("Delete", role: .destructive) {
                    Task {
                        switch await CommunityDeletionRun.run(pending) {
                        case .deleted: onDeleted(pending)
                        case .failed(let message): failure = message
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(CommunityDeletion.confirmMessage)
            }
            .alert("Couldn't delete it",
                   isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                   presenting: failure) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }
}
