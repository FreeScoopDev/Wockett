import Testing
import Foundation
@testable import PoCSquat

/// The "to go" under the Community hub's Next badge (`BadgeRemaining`).
/// Every expected string is written out by hand, not derived from the code.
@MainActor
struct BadgeRemainingTests {

    /// Noon today: earns neither Early Bird nor Night Owl, which would change
    /// Badge Hunter's count (see `CommunityHubSummaryTests.now`).
    private let now: Date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()

    /// A fresh suite per test, so the simulator's own counters can't leak in.
    private let defaults: UserDefaults = {
        let name = "BadgeRemainingTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name) ?? .standard
        suite.removePersistentDomain(forName: name)
        return suite
    }()

    private let metric = Locale(identifier: "en_CA")
    private let imperial = Locale(identifier: "en_US")

    private func badge(_ id: String) throws -> WalkBadge {
        try #require(walkBadges.first { $0.id == id })
    }

    private func session(km: Double, activity: String = "walking", pets: [UUID] = [],
                         flagged: Bool = false) -> WalkSession {
        WalkSession(id: UUID(), routeName: "Walk", date: now, elapsedTime: km * 720,
                    totalDistance: km * 1000, waypoints: [], lapCount: 1, isLoop: false,
                    activePetIds: pets, activityType: activity, flaggedPossibleVehicle: flagged)
    }

    private func remaining(_ id: String, _ sessions: [WalkSession] = [], streak: Int = 0,
                           locale: Locale? = nil) throws -> String? {
        BadgeRemaining.text(for: try badge(id), sessions: sessions, currentStreak: streak,
                            defaults: defaults, locale: locale ?? metric)
    }

    // MARK: Distance

    @Test("Distance left is in the locale's units, rounded up to a tenth")
    func distanceInUnits() throws {
        // First Steps is 1 km. 0.4 km walked leaves 600 m:
        // 0.6 km, and 600 / 1609.34 = 0.373 mi, rounded up to 0.4 mi.
        let walked = [session(km: 0.4)]
        #expect(try remaining("first", walked, locale: metric) == "0.6 km to go")
        #expect(try remaining("first", walked, locale: imperial) == "0.4 mi to go")
        // Warming Up is 10 km: 9.6 km left, 9600 / 1609.34 = 5.965 mi -> 6.0 mi.
        #expect(try remaining("warming", walked, locale: metric) == "9.6 km to go")
        #expect(try remaining("warming", walked, locale: imperial) == "6.0 mi to go")
    }

    @Test("An exact tenth left is not rounded up a further tenth")
    func exactTenths() throws {
        // A manual Past Walk of "0.7" km is exactly 700 m, but 1 - 0.7 in km
        // is 0.30000000000000004, which rounded up read "0.4 km" (critic, F3).
        #expect(try remaining("first", [session(km: 0.7)]) == "0.3 km to go")
        #expect(try remaining("warming", [session(km: 8.2)]) == "1.8 km to go")
        // Under half a metre left still reads as something left, not "0.0".
        #expect(try remaining("first", [session(km: 0.9996)]) == "0.1 km to go")
        #expect(try remaining("first", [session(km: 0.9996)], locale: imperial) == "0.1 mi to go")
    }

    @Test("A walk badge's remainder counts walks only, on the sessions the percentage uses")
    func distanceUsesProgressTotal() throws {
        // A 5 km ride and a 50 km walk flagged as driven count for neither
        // the percentage nor the remainder of First Steps (1 km).
        let sessions = [session(km: 0.4), session(km: 5, activity: "cycling"), session(km: 50, flagged: true)]
        #expect(try remaining("first", sessions) == "0.6 km to go")
        let clean = CommunityHubSummary.badgeSessions(sessions)
        let progress = try badge("first").progress(sessions: clean, currentStreak: 0, defaults: defaults)
        #expect(abs(progress - 0.4) < 0.000_1, "40% done and 0.6 km to go describe the same total")
    }

    @Test("A ride badge counts rides only; whole units from 10 up, rounded up")
    func rideBadge() throws {
        // Century Ride is 100 km cycled. 40 km ridden (the 30 km walk doesn't
        // count) leaves 60 km; 60000 / 1609.34 = 37.28 mi, rounded up to 38.
        let sessions = [session(km: 40, activity: "cycling"), session(km: 30)]
        #expect(try remaining("centuryride", sessions, locale: metric) == "60 km to go")
        #expect(try remaining("centuryride", sessions, locale: imperial) == "38 mi to go")
    }

    // MARK: Counts

    @Test("Streaks say day or days")
    func streakPlural() throws {
        #expect(try remaining("week1", streak: 6) == "1 day to go")
        #expect(try remaining("week1", streak: 5) == "2 days to go")
    }

    @Test("Not started: the whole target is left")
    func zeroProgress() throws {
        #expect(try remaining("week1", streak: 0) == "7 days to go")
        #expect(try remaining("first", locale: imperial) == "0.7 mi to go", "1000 / 1609.34 = 0.621, up to 0.7")
        #expect(try remaining("pawprints") == "25 walks with a pet to go")
        #expect(try remaining("badgehunter") == "5 badges to go")
    }

    @Test("Badge Hunter counts the other badges earned")
    func badgeCount() throws {
        // A 1.5 km noon walk earns First Steps alone: 4 of 5 to go.
        #expect(try remaining("badgehunter", [session(km: 1.5)]) == "4 badges to go")
        // 12 km earns First Steps and Warming Up; two flags earn two more.
        defaults.set(true, forKey: "wkt_customRouteCreated")
        defaults.set(true, forKey: "wkt_challengeShared")
        #expect(try remaining("badgehunter", [session(km: 12)]) == "1 badge to go")
    }

    @Test("Counted badges name what is counted")
    func counts() throws {
        let nala = UUID()
        let petWalks = (0..<23).map { _ in session(km: 1, pets: [nala]) }
        #expect(try remaining("pawprints", petWalks) == "2 walks with a pet to go")
        #expect(try remaining("firstwalkies") == "1 walk with a pet to go")
        defaults.set(7, forKey: "wkt_routesBookmarked_count")
        #expect(try remaining("routescout") == "3 bookmarks to go")
        #expect(try remaining("indoorally", [session(km: 0, activity: "stationary")]) == "4 indoor walks to go")
        #expect(try remaining("trailblazer") == "5 community routes to go")
        #expect(try remaining("notetaker") == "10 walks with notes to go")
        #expect(try remaining("historian") == "1 past walk to go")
        #expect(try remaining("firstwockett") == "1 Wockett to go")
    }

    // MARK: No remainder

    @Test("Done-or-not badges have no remainder, earned or not")
    func binaryBadges() throws {
        let binary = ["earlybird", "nightowl", "crosstrain", "packleader",
                      "cartographer", "communitybuilder", "challengeaccepted"]
        for id in binary {
            #expect(try remaining(id) == nil, "\(id) unearned")
        }
        // Earn the two flag badges: still nil.
        defaults.set(true, forKey: "wkt_customRouteCreated")
        defaults.set(true, forKey: "wkt_customRouteShared")
        #expect(try remaining("cartographer") == nil)
        #expect(try remaining("communitybuilder") == nil)
    }

    @Test("An earned badge has no remainder")
    func earned() throws {
        #expect(try remaining("first", [session(km: 2)]) == nil)
        #expect(try remaining("week1", streak: 7) == nil)
        #expect(try remaining("week1", streak: 30) == nil)
    }
}
