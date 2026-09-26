import Testing
import CloudKit
import CoreLocation
import Foundation
@testable import PoCSquat

/// What the Community hub decides to show (`CommunityHubSummary`).
@MainActor
struct CommunityHubSummaryTests {

    /// Noon today, local time. A fixed timestamp fell in the evening on one
    /// machine and in another hour on Xcode Cloud (UTC), so the walks earned
    /// Night Owl or Early Bird on one and not the other, and Badge Hunter
    /// jumped the badge order (CI, 2026-09-26). Noon earns neither.
    private let now: Date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()

    private func walk(km: Double, daysAgo: Double = 0, pets: [UUID: Double] = [:],
                      flagged: Bool = false) -> WalkSession {
        WalkSession(id: UUID(), routeName: "Walk", date: now.addingTimeInterval(-daysAgo * 86_400),
                    elapsedTime: km * 720, totalDistance: km * 1000, waypoints: [], lapCount: 1, isLoop: false,
                    activePetIds: Array(pets.keys), petDistances: pets,
                    flaggedPossibleVehicle: flagged)
    }

    // MARK: Badges

    @Test("A walk flagged as driven does not earn badges on the hub, as on the Badges screen")
    func flaggedWalksDoNotCount() {
        let driven = [walk(km: 60, flagged: true)]
        #expect(CommunityHubSummary.earnedCount(walkBadges, sessions: driven, currentStreak: 0) == 0)
        let walked = [walk(km: 60)]
        #expect(CommunityHubSummary.earnedCount(walkBadges, sessions: walked, currentStreak: 0) >= 3,
                "First Steps, Warming Up and On a Roll")
    }

    @Test("Next badges are the unearned ones closest to done, most progress first")
    func nextBadgesOrder() throws {
        // 24 walks of 1.5 km with Nala: 36 km in all. Paw Prints (25 pet walks,
        // late in the catalogue) is 96% there; On a Roll (50 km, early) is 72%.
        let nala = UUID()
        let sessions = (0..<24).map { walk(km: 1.5, daysAgo: Double($0) * 3, pets: [nala: 1500]) }
        let next = CommunityHubSummary.nextBadges(walkBadges, sessions: sessions, currentStreak: 0)
        #expect(next.map(\.badge.name).prefix(2) == ["Paw Prints", "On a Roll"])
        #expect(abs((next.first?.progress ?? 0) - 0.96) < 0.01)
        #expect(next.count == 3)
        #expect(zip(next, next.dropFirst()).allSatisfy { $0.progress >= $1.progress })
        #expect(!next.contains { $0.badge.name == "First Steps" }, "earned badges are not next")
    }

    // MARK: Challenge standing

    @Test("Rank counts everyone ahead of your live progress, and names the person just ahead")
    func standing() {
        let board: [(name: String, value: Int, isYou: Bool)] = [
            ("Leader", 150_000, false), ("SwiftFern", 101_480, false),
            ("You", 90_000, true), ("QuietOtter", 94_002, false)
        ]
        // The board stored 90,000 for you; you have walked 96,210 since.
        let s = CommunityHubSummary.standing(leaderboard: board, yourValue: 96_210)
        #expect(s == .init(rank: 3, total: 4, aheadName: "SwiftFern", gapToAhead: 5_270))
        let lead = CommunityHubSummary.standing(leaderboard: board, yourValue: 200_000)
        #expect(lead.rank == 1 && lead.aheadName == nil && lead.gapToAhead == nil)
    }

    @Test("The nudge says how long a walk gets you past the person ahead")
    func nudge() {
        #expect(CommunityHubSummary.nudge(goal: .steps, gap: 3_950, aheadName: "SwiftFern", rank: 4, activity: nil)
                == "A 40-minute walk puts you past SwiftFern into #3.")
        #expect(CommunityHubSummary.nudge(goal: .distance, gap: 2_000, aheadName: "Otter", rank: 2, activity: nil)
                == "A 30-minute walk puts you past Otter into #1.")
        #expect(CommunityHubSummary.nudge(goal: .pace, gap: 0, aheadName: "Otter", rank: 2, activity: "running")
                == "1 more qualifying run puts you past Otter into #1.")
        #expect(CommunityHubSummary.nudge(goal: .steps, gap: nil, aheadName: nil, rank: 1, activity: nil) == nil)
        #expect(CommunityHubSummary.walkMinutes(0.4) == 5, "never 'a 0-minute walk'")
    }

    // MARK: Crew

    @Test("Each pet's week: walks, distance, and a bar per day ending today")
    func crewWeek() throws {
        let nala = UUID(), hog = UUID()
        let sessions = [
            walk(km: 2, daysAgo: 0, pets: [nala: 2000, hog: 1500]),
            walk(km: 3, daysAgo: 2, pets: [nala: 3000]),
            walk(km: 4, daysAgo: 9, pets: [nala: 4000])   // last week: not counted
        ]
        let week = CommunityHubSummary.crewWeek(pets: [(nala, "Nala"), (hog, "Boss Hog")], sessions: sessions, now: now)
        let n = try #require(week.first)
        #expect(n.walks == 2 && n.meters == 5000)
        #expect(n.daily.count == 7 && n.daily.last == 2000 && n.daily[4] == 3000)
        #expect(week[1].walks == 1 && week[1].meters == 1500)
        #expect(CommunityHubSummary.walksTogether(petIDs: [nala, hog], sessions: sessions, now: now) == 1)
        #expect(CommunityHubSummary.walksTogether(petIDs: [nala], sessions: sessions, now: now) == 0,
                "one pet can't walk with the crew")
    }

    // MARK: Routes and names

    private func route(_ name: String, wocketts: Int, latitude: Double = 35.78) throws -> SharedRoute {
        let record = CKRecord(recordType: "CommunityRoute", recordID: CKRecord.ID(recordName: name))
        record["name"] = name
        record["waypointsJSON"] = "[{\"latitude\":\(latitude),\"longitude\":-78.64}]"
        record["distanceMeters"] = 1000.0
        record["upvotes"] = wocketts
        return try #require(SharedRoute(record: record))
    }

    @Test("Top routes are ranked by wocketts, most first, and capped")
    func topRoutes() throws {
        let routes = [try route("a", wocketts: 3), try route("b", wocketts: 31),
                      try route("c", wocketts: 0), try route("d", wocketts: 19)]
        #expect(CommunityHubSummary.topRoutes(routes, limit: 3).map(\.name) == ["b", "d", "a"])
    }

    @Test("Routes near you come first, ranked by wocketts; far ones follow, never dropped")
    func topRoutesNearYouFirst() throws {
        let here = CLLocation(latitude: 35.78, longitude: -78.64)
        let routes = [try route("far-popular", wocketts: 40, latitude: 38.2),    // ~168 mi north
                      try route("near-a", wocketts: 2),
                      try route("near-b", wocketts: 9, latitude: 35.9),          // ~8 mi
                      try route("far-b", wocketts: 5, latitude: 40.0)]
        #expect(CommunityHubSummary.topRoutes(routes, near: here).map(\.name)
                == ["near-b", "near-a", "far-popular", "far-b"])
        #expect(CommunityHubSummary.topRoutes(routes, near: nil).first?.name == "far-popular",
                "no location: plain ranking by wocketts")
    }

    @Test("Initials for avatars")
    func initials() {
        #expect(CommunityHubSummary.initials("SwiftFern") == "SF")
        #expect(CommunityHubSummary.initials("nala") == "NA")
        #expect(CommunityHubSummary.initials("Boss Hog") == "BH")
    }
}
