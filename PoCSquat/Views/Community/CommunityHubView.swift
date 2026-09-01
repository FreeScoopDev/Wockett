import SwiftUI
import Combine

// MARK: - Community Destination

enum CommunityDestination: Hashable {
    case badges
    case achievementFeed
    case challenges
    case communityRoutes
}

// MARK: - Tab Router

final class TabRouter: ObservableObject {
    @Published var selected: AppTab = .home
    @Published var pendingCommunityDestination: CommunityDestination? = nil
}

// MARK: - Community Hub View

struct CommunityHubView: View {
    @EnvironmentObject private var tabRouter: TabRouter
    @EnvironmentObject private var historyStore: WalkHistoryStore
    @Environment(CommunityRoutesModel.self) private var communityRoutesModel

    var streakStore: StreakStore = .shared

    @State private var pushBadges    = false
    @State private var pushFeed      = false
    @State private var pushChallenges = false
    @State private var pushRoutes    = false

    private var currentStreak: Int { streakStore.currentStreak }
    private var earnedBadgeCount: Int {
        walkBadges.filter {
            $0.isEarned(sessions: historyStore.sessions, currentStreak: currentStreak)
        }.count
    }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    hubCard(
                        icon: "flame.fill",
                        iconColor: .earthOrange,
                        title: "Streaks & Badges",
                        detail: streakDetail
                    ) { pushBadges = true }

                    hubCard(
                        icon: "medal.fill",
                        iconColor: Color(red: 0.93, green: 0.50, blue: 0.38),
                        title: "Achievement Feed",
                        detail: "Community milestones"
                    ) { pushFeed = true }

                    hubCard(
                        icon: "trophy.fill",
                        iconColor: .earthGreen,
                        title: "Challenges",
                        detail: "Compete with walkers worldwide"
                    ) { pushChallenges = true }

                    hubCard(
                        icon: "person.2.wave.2",
                        iconColor: Color.accentRide,
                        title: "Community Routes",
                        detail: "Routes shared by other walkers"
                    ) { pushRoutes = true }
                }
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Community")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(isPresented: $pushBadges) {
            BadgesContentView()
        }
        .navigationDestination(isPresented: $pushFeed) {
            AchievementFeedContentView()
        }
        .navigationDestination(isPresented: $pushChallenges) {
            ChallengesContentView()
        }
        .navigationDestination(isPresented: $pushRoutes) {
            CommunityRoutesView()
        }
        .onChange(of: tabRouter.pendingCommunityDestination) { _, dest in
            guard let dest else { return }
            switch dest {
            case .badges:          pushBadges     = true
            case .achievementFeed: pushFeed       = true
            case .challenges:      pushChallenges = true
            case .communityRoutes: pushRoutes     = true
            }
            tabRouter.pendingCommunityDestination = nil
        }
        .task { await communityRoutesModel.load() }
    }

    private var streakDetail: String {
        let streak = currentStreak
        let total  = walkBadges.count
        return streak > 0
            ? "🔥 \(streak)-day streak · \(earnedBadgeCount)/\(total) badges"
            : "\(earnedBadgeCount)/\(total) badges earned"
    }

    private func hubCard(
        icon: String,
        iconColor: Color,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(iconColor.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(iconColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.wktHeading(17))
                        .foregroundColor(.earthCream)
                    Text(detail)
                        .font(.wktBody(13))
                        .foregroundColor(.earthMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.earthMuted.opacity(0.5))
            }
            .padding(16)
            .background(Color.earthCard)
            .cornerRadius(18)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.97))
    }
}

// MARK: - Preview

#Preview("Community Hub") {
    NavigationStack {
        CommunityHubView()
    }
    .environmentObject(TabRouter())
    .environmentObject(WalkHistoryStore())
    .environment(CommunityRoutesModel())
}
