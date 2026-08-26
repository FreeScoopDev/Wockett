import SwiftUI
import CloudKit

// MARK: - Achievement Feed View

struct AchievementFeedView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var posts:        [AchievementPost] = []
    @State private var isLoading     = false
    @State private var loadError:    String?            = nil

    var body: some View {
        NavigationStack {
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
                        LazyVStack(spacing: 12) {
                            ForEach($posts) { $post in
                                AchievementPostCard(post: $post, onHide: { posts.removeAll { $0.id == post.id } })
                                    .padding(.horizontal)
                            }
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 32)
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Achievement Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.earthGreen)
                }
                ToolbarItem(placement: .primaryAction) {
                    if isLoading {
                        ProgressView().tint(.earthGreen).scaleEffect(0.8)
                    } else {
                        Button { Task { await load() } } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.earthGreen)
                        }
                    }
                }
            }
        }
        .task { await load() }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("🏅").font(.system(size: 52))
            Text("No achievements shared yet")
                .font(.headline).foregroundColor(.earthCream)
            Text("Earn a badge and share it to be the first!")
                .font(.subheadline).foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.icloud")
                .font(.system(size: 36)).foregroundColor(.earthMuted)
            Text(message)
                .font(.subheadline).foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button { loadError = nil; Task { await load() } } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Color.earthCard)
                    .foregroundColor(.earthGreen)
                    .cornerRadius(10)
            }
        }
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
                loadError = "Achievement feed not yet deployed — open CloudKit Console and deploy WocketAchievement to Production."
            default:
                loadError = "Couldn't load feed (error \(ck.code.rawValue))."
            }
        } catch {
            loadError = "Couldn't load feed: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

// MARK: - Achievement Post Card

private struct AchievementPostCard: View {
    @Binding var post: AchievementPost
    var onHide: (() -> Void)? = nil
    @State private var hasLiked = false

    private let green = Color.earthGreen

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Emoji circle
            ZStack {
                Circle()
                    .fill(Color.earthGreen.opacity(0.12))
                    .frame(width: 52, height: 52)
                Text(post.badgeEmoji)
                    .font(.system(size: 26))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(post.authorName)
                        .font(.subheadline.bold())
                        .foregroundColor(.earthCream)
                    Text("earned")
                        .font(.subheadline)
                        .foregroundColor(.earthMuted)
                    Text(post.badgeName)
                        .font(.subheadline.bold())
                        .foregroundColor(.earthGreen)
                }

                if !post.message.isEmpty {
                    Text("\"\(post.message)\"")
                        .font(.footnote)
                        .foregroundColor(.earthMuted)
                        .italic()
                        .lineLimit(3)
                }

                HStack(spacing: 16) {
                    Text(timeAgo(post.createdAt))
                        .font(.caption)
                        .foregroundColor(.earthMuted.opacity(0.7))

                    Spacer()

                    Button {
                        guard !hasLiked else { return }
                        hasLiked    = true
                        post.likes += 1
                        AchievementFeedService.shared.markLiked(id: post.id)
                        Task { try? await AchievementFeedService.shared.like(id: post.id) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: hasLiked ? "heart.fill" : "heart")
                                .font(.system(size: 14))
                                .foregroundColor(hasLiked ? .red : .earthMuted)
                            if post.likes > 0 {
                                Text("\(post.likes)")
                                    .font(.caption.bold())
                                    .foregroundColor(hasLiked ? .red : .earthMuted)
                            }
                        }
                    }
                    .buttonStyle(BounceButtonStyle(scale: 0.88))
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(Color.earthCard)
        .cornerRadius(16)
        .onAppear { hasLiked = AchievementFeedService.shared.hasLiked(id: post.id) }
        .contextMenu {
            if let onHide {
                Button(role: .destructive) {
                    CommunityModerationStore.shared.report(post.id)
                    onHide()
                } label: {
                    Label("Report Post", systemImage: "flag")
                }
                Button(role: .destructive) {
                    CommunityModerationStore.shared.block(author: post.authorName)
                    onHide()
                } label: {
                    Label("Block \(post.authorName)", systemImage: "nosign")
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
                    // Badge preview
                    VStack(spacing: 8) {
                        Text(badge.emoji)
                            .font(.system(size: 64))
                        Text(badge.name)
                            .font(.title3.bold())
                            .foregroundColor(.earthCream)
                        Text(badge.description)
                            .font(.subheadline)
                            .foregroundColor(.earthMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding(.top, 8)

                    // Optional message
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add a message (optional)")
                            .font(.caption.bold())
                            .foregroundColor(.earthMuted)
                            .padding(.horizontal, 4)
                        ZStack(alignment: .topLeading) {
                            if message.isEmpty {
                                Text("Share how you earned it…")
                                    .foregroundColor(.earthMuted.opacity(0.6))
                                    .font(.subheadline)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 10)
                            }
                            TextEditor(text: $message)
                                .font(.subheadline)
                                .foregroundColor(.earthCream)
                                .scrollContentBackground(.hidden)
                                .frame(height: 80)
                                .padding(4)
                        }
                        .background(Color.earthCard)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)

                    if let error = postError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // Post button
                    Button { post() } label: {
                        Group {
                            if isPosting {
                                ProgressView().tint(.white)
                            } else {
                                Label(
                                    didPost ? "Posted!" : "Post to Community",
                                    systemImage: didPost ? "checkmark.circle.fill" : "paperplane.fill"
                                )
                                .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(didPost ? Color.earthGreen.opacity(0.6) : Color.earthGreen)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                    }
                    .disabled(isPosting || didPost)
                    .padding(.horizontal)

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
                postError = "Sign into iCloud in Settings to share achievements."
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
                    postError = "Schema not deployed yet. Open CloudKit Console → Deploy WocketAchievement to Production."
                case .networkUnavailable, .networkFailure:
                    postError = "No internet connection."
                default:
                    postError = "Couldn't post (error \(ck.code.rawValue))."
                }
                isPosting = false
            } catch {
                postError = error.localizedDescription
                isPosting = false
            }
        }
    }
}
