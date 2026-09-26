import Foundation
import Observation

// MARK: - Community hub data
//
// The CloudKit and HealthKit reads behind the hub: active challenges (and,
// for the one you joined, the leaderboard and your live progress), the three
// latest community posts, and the wocketts your shared routes have received.
// Loaded once when the tab first appears and again on pull-to-refresh, so
// opening the tab costs three public-database reads, not one per render.
// Each part fails on its own: a feed that can't load hides its section and
// leaves the rest of the hub working.

@MainActor
@Observable
final class CommunityHubModel {
    private(set) var challenges: [WalkChallenge] = []
    private(set) var yourChallenge: WalkChallenge?
    private(set) var yourValue = 0
    private(set) var standing: CommunityHubSummary.Standing?
    private(set) var challengesFailed = false

    var posts: [AchievementPost] = []
    private(set) var feedFailed = false

    private(set) var receivedWocketts: Int?

    private(set) var isLoading = false
    private(set) var didLoad = false

    func load(sessions: [WalkSession], force: Bool = false) async {
        guard !isLoading, force || !didLoad else { return }
        isLoading = true
        defer { isLoading = false; didLoad = true }

        async let challengeList = try? ChallengeService.shared.fetchActiveChallenges()
        async let feed = try? AchievementFeedService.shared.fetchPosts(limit: 3)
        async let wocketts = CommunityRouteService.shared.fetchReceivedWocketts()

        if let list = await challengeList {
            challenges = list.filter(\.isActive)
            challengesFailed = false
        } else {
            challengesFailed = true
        }
        if let feed = await feed {
            posts = feed
            feedFailed = false
        } else {
            feedFailed = true
        }
        receivedWocketts = await wocketts

        await loadYourChallenge(sessions: sessions)
    }

    /// The first active challenge you joined: your progress and your place.
    private func loadYourChallenge(sessions: [WalkSession]) async {
        guard let joined = challenges.first(where: { ChallengeService.shared.hasJoined($0) }) else {
            yourChallenge = nil
            standing = nil
            return
        }
        let value = joined.goalType == .steps
            ? await ChallengeService.shared.fetchSteps(for: joined)
            : joined.localProgressValue(from: sessions)
        yourChallenge = joined
        yourValue = value
        if let board = try? await ChallengeService.shared.fetchLeaderboard(for: joined) {
            standing = CommunityHubSummary.standing(
                leaderboard: board.map { (name: $0.displayName, value: $0.steps, isYou: $0.isCurrentDevice) },
                yourValue: value)
        } else {
            standing = nil
        }
    }

    func markLiked(_ post: AchievementPost) {
        guard !AchievementFeedService.shared.hasLiked(id: post.id),
              let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        posts[index].likes += 1
        AchievementFeedService.shared.markLiked(id: post.id)
        Task { try? await AchievementFeedService.shared.like(id: post.id) }
    }
}
