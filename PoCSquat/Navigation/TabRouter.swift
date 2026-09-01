import SwiftUI
import Combine

// MARK: - App Tab

enum AppTab: Int, Hashable {
    case home, health, community, settings
}

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
