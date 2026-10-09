import SwiftUI
import CloudKit

// MARK: - Achievement Feed Content View (push-safe — no NavigationStack, no Done button)

struct AchievementFeedContentView: View {
    @State private var posts:     [AchievementPost] = []
    @State private var isLoading  = false
    @State private var loadError: String?            = nil
    @State private var likeError: String?

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()

            if isLoading && posts.isEmpty {
                ProgressView("Loading achievements…")
                    .foregroundColor(.earthMuted)
            } else if let error = loadError, posts.isEmpty {
                errorState(error)
            } else if posts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: WktSpacing.betweenCards) {
                        ForEach(posts) { post in
                            AchievementPostCard(post: post,
                                                isLiked: AchievementFeedService.shared.hasLiked(id: post.id),
                                                onLike: { like(post.id) },
                                                onHide: { posts.removeAll { $0.id == post.id } })
                        }
                    }
                    .padding(.horizontal, WktSpacing.screen)
                    .padding(.top, 12)
                    .padding(.bottom, WktSpacing.betweenSections)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle("Achievement Feed")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isLoading {
                    ProgressView().tint(.earthGreen).scaleEffect(0.8)
                } else {
                    Button { Task { await load() } } label: {
                        Image(wkt: .refresh).wktIcon(.inline, tint: .earthGreen)
                    }
                    .accessibilityLabel("Refresh feed")
                }
            }
        }
        .task { await load() }
        .alert("Like not saved", isPresented: Binding(get: { likeError != nil }, set: { if !$0 { likeError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(likeError ?? "")
        }
    }

    private var emptyState: some View {
        WktEmptyState(symbol: .badges, tint: .earthOrange,
                      title: "No achievements shared yet",
                      message: "Earn a badge and share it to be the first!")
    }

    private func errorState(_ message: String) -> some View {
        WktEmptyState(symbol: .cloudError, message: message, actionTitle: "Retry") {
            loadError = nil
            Task { await load() }
        }
    }

    /// Likes the post at once and saves it; a failed save is taken back from
    /// the post with this id, wherever it is in the list by then.
    private func like(_ id: CKRecord.ID) {
        guard !AchievementFeedService.shared.hasLiked(id: id) else { return }
        OptimisticVote.apply(
            id: id,
            change: { id, delta in OptimisticVote.adjust(&posts, id: id, by: delta, idPath: \.id, count: \.likes) },
            mark: { AchievementFeedService.shared.markLiked(id: $0) },
            unmark: { AchievementFeedService.shared.unmarkLiked(id: $0) },
            save: { try await AchievementFeedService.shared.like(id: $0) },
            failed: { likeError = CommunityVotes.failureMessage($0, noun: "like") })
    }

    private func load() async {
        isLoading  = true
        loadError  = nil
        do {
            posts = try await AchievementFeedService.shared.fetchPosts()
        } catch let ck as CKError {
            switch ck.code {
            case .notAuthenticated:
                loadError = "Sign into iCloud in Settings to view the achievement feed."
            case .networkUnavailable, .networkFailure:
                loadError = "No internet connection. Check your connection and retry."
            case .unknownItem, .invalidArguments, .internalError:
                loadError = "The achievement feed isn't available right now. Please try again later."
            default:
                loadError = "Couldn't load the feed. Please try again."
            }
        } catch {
            loadError = "Couldn't load the feed. Check your connection and try again."
        }
        isLoading = false
    }
}

// MARK: - Achievement Feed View (sheet wrapper — keeps existing callers compiling)

struct AchievementFeedView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AchievementFeedContentView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }.foregroundColor(.earthGreen)
                    }
                }
        }
    }
}

// MARK: - Achievement Post Card

private struct AchievementPostCard: View {
    let post: AchievementPost
    let isLiked: Bool
    let onLike: () -> Void
    var onHide: (() -> Void)? = nil

    private let green = Color.earthGreen

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.earthGreen.opacity(0.12))
                    .frame(width: 52, height: 52)
                Text(post.badgeEmoji)
                    .font(.system(size: 26)) // the badge's own emoji (data), not UI chrome
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                // One Text, so a long name wraps instead of squeezing three
                // separate labels into one line.
                (Text(post.authorName).foregroundColor(.earthCream)
                 + Text(" earned ").font(.wktBodyText).foregroundColor(.earthMuted)
                 + Text(post.badgeName).foregroundColor(.earthGreen))
                    .font(.wktRowTitle)

                if !post.message.isEmpty {
                    Text("\"\(post.message)\"")
                        .font(.wktBodyText)
                        .foregroundColor(.earthMuted)
                        .italic()
                        .lineLimit(3)
                }

                HStack(spacing: 16) {
                    Text(timeAgo(post.createdAt))
                        .font(.wktLabel)
                        .foregroundColor(.earthMuted)

                    Spacer()

                    Button {
                        onLike()
                    } label: {
                        // The same like pill as the Community hub's feed card.
                        HStack(spacing: 4) {
                            Image(wkt: .like)
                                .wktIcon(.inline, tint: .accentRun, filled: isLiked)
                            Text("\(post.likes)")
                                .font(.wktLabel)
                                .foregroundColor(.earthCream)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .background(Color.earthRaised, in: Capsule())
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(BounceButtonStyle(scale: 0.93))
                    .disabled(isLiked)
                    .accessibilityLabel(isLiked ? "Liked, \(post.likes) likes" : "Like, \(post.likes) likes")
                }
                .padding(.top, 2)
            }
        }
        .wktCard()
        .contextMenu {
            if let onHide {
                Button(role: .destructive) {
                    CommunityModerationStore.shared.report(post.id)
                    onHide()
                } label: {
                    Label {
                        Text("Report Post")
                    } icon: {
                        Image(wkt: .flagReport).wktIcon(.inline, tint: .red)
                    }
                }
                Button(role: .destructive) {
                    CommunityModerationStore.shared.block(author: post.authorName)
                    onHide()
                } label: {
                    Label {
                        Text("Block \(post.authorName)")
                    } icon: {
                        Image(wkt: .blockUser).wktIcon(.inline, tint: .red)
                    }
                }
            }
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let s = max(0, Int(-date.timeIntervalSinceNow))
        if s < 60   { return "just now" }
        if s < 3600 { return "\(s/60)m ago" }
        if s < 86400 { return "\(s/3600)h ago" }
        return "\(s/86400)d ago"
    }
}

// MARK: - Share Achievement Sheet (presented from BadgeEarnedView)

struct ShareAchievementSheet: View {
    let badge: WalkBadge
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var message    = ""
    @State private var isPosting  = false
    @State private var didPost    = false
    @State private var postError: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text(badge.emoji)
                            .font(.system(size: 64)) // the badge's own emoji (data)
                        Text(badge.name)
                            .font(.wktCardTitle)
                            .foregroundColor(.earthCream)
                        Text(badge.description)
                            .font(.wktBodyText)
                            .foregroundColor(.earthMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding(.top, 8)

                    WktSection(title: "Add a message (optional)") {
                        ZStack(alignment: .topLeading) {
                            if message.isEmpty {
                                Text("Share how you earned it…")
                                    .foregroundColor(.earthMuted)
                                    .font(.wktBodyText)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 10)
                            }
                            TextEditor(text: $message)
                                .font(.wktBodyText)
                                .foregroundColor(.earthCream)
                                .scrollContentBackground(.hidden)
                                .frame(height: 80)
                                .padding(4)
                        }
                        .padding(8)
                        .wktCardBackground()
                    }
                    .padding(.horizontal, WktSpacing.screen)

                    if let error = postError {
                        Text(error)
                            .font(.wktLabel)
                            .foregroundColor(.earthOrange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, WktSpacing.screen)
                    }

                    Button { post() } label: {
                        if isPosting {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .background(Color.earthGreenFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        } else {
                            WktPrimaryLabel(title: didPost ? "Posted!" : "Post to Community",
                                            symbol: didPost ? .success : .send)
                                .opacity(didPost ? 0.6 : 1)
                        }
                    }
                    .buttonStyle(BounceButtonStyle(scale: 0.98))
                    .disabled(isPosting || didPost)
                    .padding(.horizontal, WktSpacing.screen)

                    Spacer()
                }
                .padding(.top, 16)
            }
            .navigationTitle("Share Achievement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.earthMuted)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func post() {
        isPosting  = true
        postError  = nil
        Task {
            let container = CKContainer(identifier: "iCloud.Scoops.PoCSquat")
            let status    = try? await container.accountStatus()
            guard status == .available else {
                postError = "Sign in to iCloud in the Settings app to share achievements."
                isPosting = false
                return
            }
            do {
                try await AchievementFeedService.shared.post(
                    badgeName:  badge.name,
                    badgeEmoji: badge.emoji,
                    message:    message
                )
                didPost   = true
                isPosting = false
                try? await Task.sleep(nanoseconds: 900_000_000)
                dismiss()
                onDone()
            } catch let ck as CKError {
                switch ck.code {
                case .unknownItem, .invalidArguments:
                    postError = "Sharing isn't available right now. Please try again later."
                case .networkUnavailable, .networkFailure:
                    postError = "No internet connection."
                default:
                    postError = "Couldn't post. Please try again."
                }
                isPosting = false
            } catch {
                postError = "Couldn't post. Check your connection and try again."
                isPosting = false
            }
        }
    }
}
