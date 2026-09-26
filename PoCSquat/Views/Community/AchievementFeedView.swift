import SwiftUI
import CloudKit

// MARK: - Achievement Feed Content View (push-safe — no NavigationStack, no Done button)

struct AchievementFeedContentView: View {
    @State private var posts:     [AchievementPost] = []
    @State private var isLoading  = false
    @State private var loadError: String?            = nil

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
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(wkt: .badges).wktIcon(.hero, tint: .earthOrange)
                .accessibilityHidden(true)
            Text("No achievements shared yet")
                .font(.wktHeading(17)).foregroundColor(.earthCream)
            Text("Earn a badge and share it to be the first!")
                .font(.wktBody(15)).foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(wkt: .cloudError).wktIcon(.hero, tint: .earthMuted)
                .accessibilityHidden(true)
            Text(message)
                .font(.wktBody(15)).foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button { loadError = nil; Task { await load() } } label: {
                Label {
                    Text("Retry")
                } icon: {
                    Image(wkt: .refresh).wktIcon(.inline, tint: .earthGreen)
                }
                .font(.wktBody(15))
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
    @Binding var post: AchievementPost
    var onHide: (() -> Void)? = nil
    @State private var hasLiked = false

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

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(post.authorName)
                        .font(.wktHeading(15))
                        .foregroundColor(.earthCream)
                    Text("earned")
                        .font(.wktBody(15))
                        .foregroundColor(.earthMuted)
                    Text(post.badgeName)
                        .font(.wktHeading(15))
                        .foregroundColor(.earthGreen)
                }

                if !post.message.isEmpty {
                    Text("\"\(post.message)\"")
                        .font(.wktBody(13))
                        .foregroundColor(.earthMuted)
                        .italic()
                        .lineLimit(3)
                }

                HStack(spacing: 16) {
                    Text(timeAgo(post.createdAt))
                        .font(.wktBody(12))
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
                            // accentRun matches the like on the Community hub's feed card.
                            Image(wkt: .like)
                                .wktIcon(.inline, tint: hasLiked ? .accentRun : .earthMuted, filled: hasLiked)
                            if post.likes > 0 {
                                Text("\(post.likes)")
                                    .font(.wktBody(12))
                                    .foregroundColor(hasLiked ? .accentRun : .earthMuted)
                            }
                        }
                    }
                    .buttonStyle(BounceButtonStyle(scale: 0.88))
                }
                .padding(.top, 2)
            }
        }
        .wktCard(padding: 14)
        .onAppear { hasLiked = AchievementFeedService.shared.hasLiked(id: post.id) }
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
                            .font(.wktHeading(20))
                            .foregroundColor(.earthCream)
                        Text(badge.description)
                            .font(.wktBody(15))
                            .foregroundColor(.earthMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 6) {
                        WktSectionHeader(title: "Add a message (optional)")
                            .padding(.horizontal, 4)
                        ZStack(alignment: .topLeading) {
                            if message.isEmpty {
                                Text("Share how you earned it…")
                                    .foregroundColor(.earthMuted.opacity(0.6))
                                    .font(.wktBody(15))
                                    .padding(.horizontal, 8)
                                    .padding(.top, 10)
                            }
                            TextEditor(text: $message)
                                .font(.wktBody(15))
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
                            .font(.wktBody(12))
                            .foregroundColor(.earthOrange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Button { post() } label: {
                        Group {
                            if isPosting {
                                ProgressView().tint(.white)
                            } else {
                                Label {
                                    Text(didPost ? "Posted!" : "Post to Community")
                                } icon: {
                                    Image(wkt: didPost ? .success : .send)
                                        .wktIcon(.row, tint: .white, filled: true, onFill: true)
                                }
                                .font(.wktBody(17))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(didPost ? Color.earthGreenFill.opacity(0.6) : Color.earthGreenFill)
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
