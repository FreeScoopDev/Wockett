import SwiftUI
import Combine

// MARK: - App Tab

enum AppTab: Int, Hashable {
    case home, health, routes, community, settings
}

// MARK: - Community Destination

enum CommunityDestination: Hashable {
    case badges
    case achievementFeed
    case challenges
    case communityRoutes
}

// MARK: - Routes Destination

enum RoutesDestination: Hashable {
    case nearby
    /// Routes → Trails, with this trail opened when it is in the list
    /// (the Community hub's "Trails near you").
    case trails(openTrailID: String?)
}

// MARK: - Tab Router

final class TabRouter: ObservableObject {
    @Published var selected: AppTab = .home
    @Published var pendingCommunityDestination: CommunityDestination?
    @Published var pendingRoutesDestination: RoutesDestination?
    /// A walk Siri or the Control Center button asked for; Home opens the
    /// walk screen in this mode and clears it.
    @Published var pendingWalkStart: ActivityMode?
}
