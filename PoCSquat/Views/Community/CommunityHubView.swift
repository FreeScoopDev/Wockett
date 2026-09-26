import SwiftUI
import MapKit

// MARK: - Community Hub View
//
// A dashboard since 2026-09-26 (the "A+" mockup): your week, your challenge,
// the next badge, your crew's week, the latest posts, top community routes
// and official trails nearby. Every section is Home's card with Home's
// section label (`wktCard`, `WktSectionHeader`), so the tab reads as the same
// app. Before, it was four menu rows and three of them said the same thing
// whatever was happening. The decisions are in `CommunityHubSummary`, the
// CloudKit and HealthKit reads in `CommunityHubModel`.

struct CommunityHubView: View {
    @EnvironmentObject private var tabRouter: TabRouter
    @EnvironmentObject private var historyStore: WalkHistoryStore
    @EnvironmentObject private var petStore: PetStore
    @EnvironmentObject private var routeManager: RouteManager
    @EnvironmentObject private var routeStore: CustomRouteStore
    @EnvironmentObject private var stepManager: StepManager
    @Environment(CommunityRoutesModel.self) private var communityRoutesModel

    var streakStore: StreakStore = .shared

    @State private var model = CommunityHubModel()
    @State private var trailFinder = TrailFinder()

    @State private var pushBadges       = false
    @State private var pushFeed         = false
    @State private var pushChallenges   = false
    @State private var pushNewChallenge = false
    @State private var pushRoutes       = false
    @State private var pushMyRoutes     = false
    @State private var pushPets         = false

    private var sessions: [WalkSession] { historyStore.sessions }
    private var currentStreak: Int { streakStore.currentStreak }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    youCard
                    challengeCard
                    badgeCard
                    crewCard
                    feedCard
                    routesSection
                    trailsCard
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .refreshable {
                await model.load(sessions: sessions, force: true)
                await communityRoutesModel.load(force: true)
                refreshTrails()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("community.root")
        .navigationTitle("Community")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(isPresented: $pushBadges) { BadgesContentView() }
        .navigationDestination(isPresented: $pushFeed) { AchievementFeedContentView() }
        .navigationDestination(isPresented: $pushChallenges) { ChallengesContentView() }
        .navigationDestination(isPresented: $pushNewChallenge) { ChallengesContentView(startCreating: true) }
        .navigationDestination(isPresented: $pushRoutes) { CommunityRoutesView() }
        .navigationDestination(isPresented: $pushMyRoutes) {
            CustomRoutesListView(store: routeStore, historyStore: historyStore)
        }
        .navigationDestination(isPresented: $pushPets) {
            PetManagementView(historyStore: historyStore, defaultGoal: stepManager.currentGoal)
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
        .onChange(of: routeManager.lastLocation) { _, _ in refreshTrails() }
        .task {
            refreshTrails()
            await model.load(sessions: sessions)
            await communityRoutesModel.load()
            if routeManager.lastLocation == nil, !isWKTUITestMode {
                routeManager.lastLocation = await routeManager.fetchCurrentLocation()
            }
        }
    }

    // MARK: - You

    private var youCard: some View {
        let earned = CommunityHubSummary.earnedCount(walkBadges, sessions: sessions, currentStreak: currentStreak)
        let name = CommunityRouteService.shared.username
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                avatar(name, size: 48, tint: .earthGreenFill, filled: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.wktHeading(17))
                        .foregroundColor(.earthCream)
                    Text("Your week in Wockett")
                        .font(.wktBody(13))
                        .foregroundColor(.earthMuted)
                }
            }
            HStack(spacing: 0) {
                youStat(value: "\(currentStreak)", label: "DAY STREAK") { pushBadges = true }
                youStat(value: "\(earned)", label: "BADGES") { pushBadges = true }
                youStat(value: model.standing.map { "#\($0.rank)" } ?? "–", label: "CHALLENGE") { pushChallenges = true }
                youStat(value: model.receivedWocketts.map { "\($0)" } ?? "–", label: "WOCKETTS") { pushRoutes = true }
            }
            HStack(spacing: 8) {
                quickAction("Start a challenge", primary: true) { pushNewChallenge = true }
                quickAction("Share a route", primary: false) { pushMyRoutes = true }
            }
        }
        .wktCard()
    }

    private func youStat(value: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(value)
                    .font(.wktDisplay(22))
                    .foregroundColor(.earthCream)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .wktTechnical(9)
                    .foregroundColor(.earthMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(BounceButtonStyle(scale: 0.95))
        .accessibilityElement(children: .combine)
    }

    private func quickAction(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.wktBody(13))
                .foregroundColor(primary ? .white : .earthCream)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(primary ? Color.earthGreenFill : Color.earthBg)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(BounceButtonStyle(scale: 0.97))
    }

    // MARK: - Challenge

    @ViewBuilder
    private var challengeCard: some View {
        if let challenge = model.yourChallenge {
            yourChallengeCard(challenge)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                WktSectionHeader(title: "Challenges", actionTitle: "All", action: { pushChallenges = true })
                if !model.challenges.isEmpty {
                    ForEach(model.challenges.prefix(2)) { challenge in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(challenge.title)
                                    .font(.wktHeading(15))
                                    .foregroundColor(.earthCream)
                                Text("\(challenge.goalText) · \(challenge.timeRemainingText)")
                                    .font(.wktBody(12))
                                    .foregroundColor(.earthMuted)
                            }
                            Spacer()
                            compactButton("Join") { pushChallenges = true }
                        }
                    }
                } else if model.didLoad {
                    // The You card above already offers Start a challenge.
                    Text(model.challengesFailed
                         ? "Challenges couldn't load. Pull down to try again."
                         : "No challenges running right now. Start one and invite other walkers.")
                        .font(.wktBody(13))
                        .foregroundColor(.earthMuted)
                } else {
                    loadingRow
                }
            }
            .wktCard()
        }
    }

    private func yourChallengeCard(_ challenge: WalkChallenge) -> some View {
        let progress = challenge.progress(for: model.yourValue)
        return VStack(alignment: .leading, spacing: 14) {
            WktSectionHeader(title: "Your challenge", actionTitle: "All", action: { pushChallenges = true })
            Button { pushChallenges = true } label: {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().stroke(Color.earthLine, lineWidth: 9)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.earthGreen, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.wktHeading(17))
                            .foregroundColor(.earthCream)
                    }
                    .frame(width: 76, height: 76)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(challenge.title)
                            .font(.wktHeading(17))
                            .foregroundColor(.earthCream)
                        Text(challenge.progressDisplay(for: model.yourValue))
                            .font(.wktBody(12))
                            .foregroundColor(.earthMuted)
                        HStack(spacing: 6) {
                            if let standing = model.standing {
                                chip("#\(standing.rank) of \(standing.total)", tint: .earthGreen)
                            }
                            chip(challenge.timeRemainingText, tint: .earthOrange)
                        }
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            if let standing = model.standing,
               let nudge = CommunityHubSummary.nudge(goal: challenge.goalType, gap: standing.gapToAhead,
                                                     aheadName: standing.aheadName, rank: standing.rank,
                                                     activity: challenge.activityFilter) {
                Text(nudge)
                    .font(.wktBody(13))
                    .foregroundColor(.earthGreen)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.earthGreen.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if model.standing?.rank == 1 {
                Text("You're in the lead. Keep it up.")
                    .font(.wktBody(13))
                    .foregroundColor(.earthGreen)
            }
        }
        .wktCard()
    }

    // MARK: - Badges

    private var badgeCard: some View {
        let next = CommunityHubSummary.nextBadges(walkBadges, sessions: sessions, currentStreak: currentStreak)
        return VStack(alignment: .leading, spacing: 12) {
            WktSectionHeader(title: "Next badge", actionTitle: "All badges", action: { pushBadges = true })
            if let first = next.first {
                Button { pushBadges = true } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(wkt: .badges)
                                .wktIcon(.row, tint: .earthOrange, filled: true)
                                .frame(width: 48, height: 48)
                                .background(Color.earthOrange.opacity(0.14))
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(first.badge.name)
                                    .font(.wktHeading(16))
                                    .foregroundColor(.earthCream)
                                Text(first.badge.description)
                                    .font(.wktBody(12))
                                    .foregroundColor(.earthMuted)
                            }
                            Spacer()
                            Text("\(Int((first.progress * 100).rounded()))%")
                                .font(.wktHeading(16))
                                .foregroundColor(.earthOrange)
                        }
                        WktProgressBar(value: first.progress, tint: .earthOrange)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                if next.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(next.dropFirst(), id: \.badge.id) { item in
                            chip("\(item.badge.name) · \(Int((item.progress * 100).rounded()))%", tint: .earthMuted)
                        }
                    }
                }
            } else {
                Text("Every badge earned. All \(walkBadges.count) of them.")
                    .font(.wktBody(13))
                    .foregroundColor(.earthMuted)
            }
        }
        .wktCard()
    }

    // MARK: - Crew

    private var crewCard: some View {
        let pets = petStore.pets
        return VStack(alignment: .leading, spacing: 14) {
            WktSectionHeader(title: "Walks with the crew", actionTitle: "Manage", action: { pushPets = true })
            if pets.isEmpty {
                HStack(spacing: 12) {
                    Image(wkt: .pets)
                        .wktIcon(.row, tint: .earthOrange, filled: true)
                        .frame(width: 44, height: 44)
                        .background(Color.earthOrange.opacity(0.14))
                        .clipShape(Circle())
                    Text("Add your pets to see the walks you take together.")
                        .font(.wktBody(13))
                        .foregroundColor(.earthMuted)
                }
            } else {
                let week = CommunityHubSummary.crewWeek(pets: pets.map { ($0.id, $0.name) }, sessions: sessions)
                ForEach(week) { pet in
                    crewRow(pet, tint: pets.first { $0.id == pet.id }?.accentColor ?? .earthOrange)
                }
                if pets.count >= 2 {
                    let together = CommunityHubSummary.walksTogether(petIDs: pets.map(\.id), sessions: sessions)
                    Divider().overlay(Color.earthLine)
                    Text(together == 1 ? "1 walk together this week" : "\(together) walks together this week")
                        .font(.wktBody(13))
                        .foregroundColor(.earthCream)
                }
            }
        }
        .wktCard()
    }

    private func crewRow(_ pet: CommunityHubSummary.CrewWeek, tint: Color) -> some View {
        let peak = max(pet.daily.max() ?? 0, 1)
        let distance = MKDistanceFormatter.abbreviated.string(fromDistance: pet.meters)
        return HStack(spacing: 12) {
            avatar(pet.name, size: 40, tint: tint, filled: false)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(pet.name)
                        .font(.wktHeading(15))
                        .foregroundColor(.earthCream)
                    Spacer()
                    Text("\(pet.walks) walk\(pet.walks == 1 ? "" : "s") · \(distance)")
                        .font(.wktBody(12))
                        .foregroundColor(.earthMuted)
                }
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(pet.daily.enumerated()), id: \.offset) { _, meters in
                        Capsule()
                            .fill(meters > 0 ? tint : Color.earthLine)
                            .frame(height: meters > 0 ? max(6, 24 * meters / peak) : 4)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 24, alignment: .bottom)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Feed

    @ViewBuilder
    private var feedCard: some View {
        if !model.posts.isEmpty || (model.didLoad && !model.feedFailed) {
            VStack(alignment: .leading, spacing: 4) {
                WktSectionHeader(title: "From the community", actionTitle: "See all", action: { pushFeed = true })
                if model.posts.isEmpty {
                    Text("No milestones shared yet. Earn a badge and share it.")
                        .font(.wktBody(13))
                        .foregroundColor(.earthMuted)
                        .padding(.top, 8)
                }
                ForEach(Array(model.posts.enumerated()), id: \.element.id) { index, post in
                    if index > 0 { Divider().overlay(Color.earthLine) }
                    feedRow(post)
                }
            }
            .wktCard()
        }
    }

    private func feedRow(_ post: AchievementPost) -> some View {
        let liked = AchievementFeedService.shared.hasLiked(id: post.id)
        let when = Self.relative(post.createdAt)
        return HStack(spacing: 12) {
            avatar(post.authorName, size: 40, tint: Self.nameTint(post.authorName), filled: false)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(post.authorName) earned \(post.badgeName)")
                    .font(.wktHeading(14))
                    .foregroundColor(.earthCream)
                Text(post.message.isEmpty ? when : "\u{201C}\(post.message)\u{201D} · \(when)")
                    .font(.wktBody(12))
                    .foregroundColor(.earthMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { model.markLiked(post) } label: {
                HStack(spacing: 4) {
                    Image(wkt: .like).wktIcon(.inline, tint: .accentRun, filled: liked)
                    Text("\(post.likes)")
                        .font(.wktBody(13))
                        .foregroundColor(.earthCream)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .background(Color.earthBg)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(BounceButtonStyle(scale: 0.93))
            .disabled(liked)
            .accessibilityLabel(liked ? "Liked, \(post.likes) likes" : "Like, \(post.likes) likes")
        }
        .padding(.vertical, 8)
    }

    // MARK: - Community routes

    @ViewBuilder
    private var routesSection: some View {
        let top = CommunityHubSummary.topRoutes(communityRoutesModel.routes)
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                WktSectionHeader(title: "Top community routes", actionTitle: "See all", action: { pushRoutes = true })
                    .padding(.horizontal, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(top.enumerated()), id: \.element.id) { rank, route in
                            routeTile(route, rank: rank + 1)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
        }
    }

    private func routeTile(_ route: SharedRoute, rank: Int) -> some View {
        let away = CommunityHubSummary.distanceToStart(of: route, from: routeManager.lastLocation)
        let detail = [route.distanceText, route.difficulty.rawValue,
                      away.map { "\(MKDistanceFormatter.abbreviated.string(fromDistance: $0)) away" }]
            .compactMap { $0 }.joined(separator: " · ")
        return Button { pushRoutes = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    RouteShape(points: route.waypoints)
                        .stroke(Color.earthGreen, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                        .padding(18)
                        .frame(height: 104)
                        .frame(maxWidth: .infinity)
                        .background(Color.earthGreen.opacity(0.10))
                    HStack(spacing: 4) {
                        Image(wkt: .wockett).wktIcon(.inline, tint: .white, filled: true, onFill: true)
                        Text("#\(rank) · \(route.wocketts)")
                            .font(.wktBody(12))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentRideFill)
                    .clipShape(Capsule())
                    .padding(10)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(route.name)
                        .font(.wktHeading(15))
                        .foregroundColor(.earthCream)
                        .lineLimit(1)
                    Text(detail)
                        .font(.wktBody(12))
                        .foregroundColor(.earthMuted)
                        .lineLimit(1)
                    Text("by \(route.authorName)")
                        .font(.wktBody(12))
                        .foregroundColor(.earthMuted)
                        .lineLimit(1)
                }
                .padding(12)
            }
            .frame(width: 220, alignment: .leading)
            .background(Color.earthCard)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(BounceButtonStyle(scale: 0.97))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(route.name), number \(rank), \(route.wocketts) wocketts, \(detail)")
    }

    // MARK: - Trails

    @ViewBuilder
    private var trailsCard: some View {
        let nearby = Array(trailFinder.items.prefix(3))
        if !nearby.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                WktSectionHeader(title: "Trails near you", actionTitle: "Open Trails", action: { openTrails(nil) })
                ForEach(Array(nearby.enumerated()), id: \.element.id) { index, trail in
                    if index > 0 { Divider().overlay(Color.earthLine) }
                    Button { openTrails(trail.id) } label: {
                        HStack(spacing: 12) {
                            Image(wkt: trail.isLoop ? .loop : .routeTrail)
                                .wktIcon(.row, tint: .earthGreen)
                                .frame(width: 44, height: 44)
                                .background(Color.earthGreen.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(trail.name)
                                    .font(.wktHeading(15))
                                    .foregroundColor(.earthCream)
                                    .lineLimit(1)
                                Text(trailDetail(trail))
                                    .font(.wktBody(12))
                                    .foregroundColor(.earthMuted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            chip("Official", tint: .earthGreen)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                }
                TrailCreditLine()
                    .padding(.top, 6)
            }
            .wktCard()
        }
    }

    private func trailDetail(_ trail: TrailListItem) -> String {
        let length = MKDistanceFormatter.abbreviated.string(fromDistance: trail.lengthMeters)
        var parts = [trail.isLoop ? "\(length) loop" : length]
        if let surface = trail.surfaceKind { parts.append(surface == .paved ? "Paved" : "Unpaved") }
        parts.append("\(MKDistanceFormatter.abbreviated.string(fromDistance: trail.distanceMeters)) away")
        return parts.joined(separator: " · ")
    }

    private func refreshTrails() {
        trailFinder.refresh(near: routeManager.lastLocation?.coordinate, grouped: true, cycling: false,
                            usesMiles: Locale.current.measurementSystem == .us)
    }

    private func openTrails(_ id: String?) {
        tabRouter.pendingRoutesDestination = .trails(openTrailID: id)
        tabRouter.selected = .routes
    }

    // MARK: - Pieces

    private func avatar(_ name: String, size: CGFloat, tint: Color, filled: Bool) -> some View {
        Text(CommunityHubSummary.initials(name))
            .font(.wktHeading(size * 0.34))
            .foregroundColor(filled ? .white : tint)
            .frame(width: size, height: size)
            .background(filled ? tint : tint.opacity(0.14))
            .clipShape(Circle())
            .accessibilityHidden(true)
    }

    private func chip(_ text: String, tint: Color) -> some View {
        let neutral = tint == .earthMuted
        return Text(text)
            .font(.wktBody(11))
            .foregroundColor(neutral ? .earthCream : tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(neutral ? Color.earthBg : tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func compactButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.wktBody(13))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Color.earthGreenFill)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(BounceButtonStyle(scale: 0.95))
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().tint(.earthGreen)
            Text("Loading…")
                .font(.wktBody(13))
                .foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    /// One of four tints per name, the same every launch (String.hashValue is not).
    static func nameTint(_ name: String) -> Color {
        let tints: [Color] = [.earthGreen, .accentRide, .accentIndoor, .earthOrange]
        return tints[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % tints.count]
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Route shape

/// A route's outline, scaled into the tile, for the carousel: cheaper than a
/// map snapshot per tile, and the shape is what tells routes apart.
private struct RouteShape: Shape {
    let points: [WaypointCoord]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return path }
        let cosLat = cos(((minLat + maxLat) / 2) * .pi / 180)
        let width = max((maxLon - minLon) * cosLat, 1e-9), height = max(maxLat - minLat, 1e-9)
        let scale = min(rect.width / width, rect.height / height)
        let offsetX = rect.minX + (rect.width - width * scale) / 2
        let offsetY = rect.minY + (rect.height - height * scale) / 2
        for (i, p) in points.enumerated() {
            let point = CGPoint(x: offsetX + (p.longitude - minLon) * cosLat * scale,
                                y: offsetY + (maxLat - p.latitude) * scale)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
