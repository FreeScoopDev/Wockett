#if DEBUG
import Foundation
import MapKit

// MARK: - Developer Seed Store
// Generates realistic fake data for testing streaks, badges, calendar, and routes.
// All fake records are prefixed with "[TEST]" so they can be cleared independently.

struct DevSeedStore {
    private static let tag = "[TEST]"

    // MARK: - Walk Sessions

    static func seedWalkSessions(into store: WalkHistoryStore) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        let goalNames  = ["[TEST] Morning Loop", "[TEST] Park Circuit", "[TEST] River Trail",
                          "[TEST] Hill Route",   "[TEST] Neighborhood Loop", "[TEST] Sunrise Walk"]
        let lightNames = ["[TEST] Quick Stroll", "[TEST] Evening Walk", "[TEST] Lunch Walk"]

        var toAdd: [WalkSession] = []

        // 35 consecutive goal days ending yesterday — builds a 35-day streak
        for daysAgo in 1...35 {
            guard let day = cal.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            let count = Int.random(in: 2...3)
            var remaining = Double.random(in: 8800...11500)
            for i in 0..<count {
                let dist = i < count - 1 ? remaining * Double.random(in: 0.4...0.6) : remaining
                remaining -= dist
                let date = day.addingTimeInterval(TimeInterval(i) * 3600 + Double.random(in: 0...600))
                toAdd.append(session(name: goalNames.randomElement()!, date: date, distance: dist))
            }
        }

        // 40 older days — mix of goal, light, and rest days
        for daysAgo in 36...75 {
            guard let day = cal.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            let roll = Int.random(in: 0...2)
            if roll == 0 { continue } // rest day
            let (dist, name): (Double, String) = roll == 1
                ? (Double.random(in: 8500...12000), goalNames.randomElement()!)
                : (Double.random(in: 2000...5000),  lightNames.randomElement()!)
            let date = day.addingTimeInterval(Double.random(in: 3600...72000))
            toAdd.append(session(name: name, date: date, distance: dist))
        }

        store.addAll(toAdd)
    }

    static func clearTestSessions(from store: WalkHistoryStore) {
        let indices = IndexSet(
            store.sessions.enumerated()
                .filter { $0.element.routeName.hasPrefix(tag) }
                .map(\.offset)
        )
        if !indices.isEmpty { store.delete(at: indices) }
    }

    // MARK: - Custom Routes

    static func seedCustomRoutes(into store: CustomRouteStore) {
        let templates: [(String, [(Double, Double)], Double, Bool)] = [
            ("[TEST] Central Park Loop",
             [(40.7681,-73.9816),(40.7812,-73.9665),(40.7955,-73.9513),(40.7900,-73.9580),(40.7681,-73.9816)],
             9700, true),
            ("[TEST] Waterfront Out & Back",
             [(40.7027,-74.0160),(40.7128,-74.0099),(40.7218,-74.0050)],
             5200, false),
            ("[TEST] Morning 5K",
             [(40.7589,-73.9851),(40.7620,-73.9790),(40.7650,-73.9720),(40.7589,-73.9851)],
             5000, true),
            ("[TEST] Neighborhood Stroll",
             [(40.7484,-73.9967),(40.7520,-73.9920),(40.7560,-73.9880)],
             3200, false),
        ]
        let age: [Double] = [86400, 172800, 345600, 604800]
        for (i, t) in templates.enumerated().reversed() {
            let waypoints = t.1.map { WaypointCoord(CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1)) }
            store.save(CustomRoute(
                id: UUID(), name: t.0, waypoints: waypoints,
                totalDistance: t.2, isLoop: t.3,
                createdAt: Date().addingTimeInterval(-age[i])
            ))
        }
    }

    static func clearTestRoutes(from store: CustomRouteStore) {
        let indices = IndexSet(
            store.routes.enumerated()
                .filter { $0.element.name.hasPrefix(tag) }
                .map(\.offset)
        )
        if !indices.isEmpty { store.delete(at: indices) }
    }

    // MARK: - Screenshot Demo

    private static let demoTag        = "[DEMO]"
    private static let demoPetNames   = ["Nala", "Beef"]
    private static let demoRouteNames = ["Central Park Loop", "Waterfront Out & Back",
                                         "Morning 5K", "Neighborhood Stroll"]

    // Same coordinates as the [TEST] templates — clean names only.
    private static let demoRouteTemplates: [(String, [(Double, Double)], Double, Bool)] = [
        ("Central Park Loop",
         [(40.7681,-73.9816),(40.7812,-73.9665),(40.7955,-73.9513),(40.7900,-73.9580),(40.7681,-73.9816)],
         9_700, true),
        ("Waterfront Out & Back",
         [(40.7027,-74.0160),(40.7128,-74.0099),(40.7218,-74.0050)],
         5_200, false),
        ("Morning 5K",
         [(40.7589,-73.9851),(40.7620,-73.9790),(40.7650,-73.9720),(40.7589,-73.9851)],
         5_000, true),
        ("Neighborhood Stroll",
         [(40.7484,-73.9967),(40.7520,-73.9920),(40.7560,-73.9880)],
         3_200, false),
    ]

    /// Seeds realistic, screenshot-ready app data.
    /// Tag: notes = "[DEMO]" on every session; pets and routes tracked by name.
    ///
    /// Screenshot day:
    ///   1. Simulator: xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
    ///   2. Settings → Developer → Seed screenshot demo
    ///   3. Shots 1,5,6,7,8,9 in the simulator; 2,3,4 on device after a real ~10-min walk (Live Activity + PR need real hardware)
    ///   4. Settings → Developer → Clear demo data when done
    ///
    /// Note: HealthKit step seeding is skipped. Walking paces are ~17 min/km so a real
    /// 10-min device walk earns a "fastest pace" PR for shot #3. For shot #7 (step ring)
    /// switch Data Source to "App Only" — session steps then drive the ring.
    static func seedScreenshotDemo(history: WalkHistoryStore, pets petStore: PetStore, routes: CustomRouteStore) {
        clearScreenshotDemo(history: history, pets: petStore, routes: routes)

        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())

        // --- Pets ---
        let nala = PetProfile(name: "Nala", species: "Dog", breed: "Golden Retriever",
                              goalSteps: 8_000, accentColorIndex: 0, isActiveOnWalk: true)
        let beef = PetProfile(name: "Beef", species: "Dog", breed: "Corgi",
                              goalSteps: 6_000, accentColorIndex: 2, isActiveOnWalk: false)
        petStore.add(nala)
        petStore.add(beef)

        // --- Routes ---
        let routeAges: [Double] = [86_400, 172_800, 345_600, 604_800]
        for (i, t) in demoRouteTemplates.enumerated().reversed() {
            let wps = t.1.map { WaypointCoord(CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1)) }
            routes.save(CustomRoute(id: UUID(), name: t.0, waypoints: wps,
                                    totalDistance: t.2, isLoop: t.3,
                                    createdAt: Date().addingTimeInterval(-routeAges[i])))
        }

        // --- Sessions ---
        // (daysAgo, hour, minute, distMeters, activityType, withBothPets, nalaPct)
        // Days 0-8: no-gap streak window.
        // Paces: walking ~17 min/km (slow — real device walk beats it for PR shot).
        //        running ~7 min/km, cycling ~18 km/h.
        typealias P = (daysAgo: Int, h: Int, m: Int, d: Double, type: String, pets: Bool, nPct: Double)
        let plan: [P] = [
            // Today: short morning walk so pet rings + dashboard are non-zero
            (0,  7, 30,  2_100, "walking", true,  0.55),
            // Day 1
            (1,  7, 15,  4_200, "walking", true,  0.55),
            (1, 17, 45,  4_800, "walking", true,  0.52),
            // Day 2
            (2,  8,  0,  3_800, "walking", true,  0.58),
            (2, 18, 30,  5_000, "walking", true,  0.54),
            // Day 3: run + walk
            (3,  6, 45,  5_000, "running", false, 0.00),
            (3, 16,  0,  4_000, "walking", true,  0.55),
            // Day 4
            (4,  7, 30,  4_000, "walking", true,  0.56),
            (4, 17, 15,  5_500, "walking", true,  0.53),
            // Day 5: ride + walk (ride alone clears 10k-step threshold via distance fallback)
            (5,  8,  0, 14_000, "cycling", false, 0.00),
            (5, 16, 30,  2_800, "walking", true,  0.55),
            // Day 6
            (6,  7,  0,  4_500, "walking", true,  0.57),
            (6, 18,  0,  3_800, "walking", true,  0.54),
            // Day 7: run + walk
            (7,  6, 30,  5_500, "running", false, 0.00),
            (7, 16, 45,  4_200, "walking", true,  0.55),
            // Day 8
            (8,  8, 15,  4_100, "walking", true,  0.56),
            (8, 18, 30,  4_600, "walking", true,  0.53),
            // Days 9-13: older history for badge depth, calendar fill, earlyBird/nightOwl
            (9,  7, 30,  3_500, "walking", true,  0.55),
            (9, 17,  0,  4_000, "walking", false, 0.00),
            (10, 8, 30,  4_500, "walking", true,  0.54),
            (11, 7,  0,  3_200, "walking", true,  0.56),
            (11,20, 15,  3_800, "walking", false, 0.00), // NightOwl badge
            (12, 6, 45,  4_800, "walking", true,  0.55), // EarlyBird badge
            (13, 7, 30,  3_600, "walking", true,  0.57),
            (13,17, 30,  4_200, "walking", true,  0.53),
        ]

        let walkNames = ["Sunrise Loop", "Neighborhood Loop", "Park Circuit",
                         "Riverside Out & Back", "Evening Stroll"]

        var sessions: [WalkSession] = []
        for (idx, p) in plan.enumerated() {
            guard let base = cal.date(byAdding: .day, value: -p.daysAgo, to: today) else { continue }
            let date = base.addingTimeInterval(TimeInterval(p.h * 3600 + p.m * 60))

            let elapsed: TimeInterval
            let steps: Int
            switch p.type {
            case "running": elapsed = p.d * 0.42; steps = Int(p.d * 1.1)
            case "cycling": elapsed = p.d * 0.18; steps = 0
            default:        elapsed = p.d * 1.02; steps = Int(p.d * 1.3)
            }

            var petIds:   [UUID]           = []
            var petDists: [UUID: Double]   = [:]
            if p.pets {
                petIds   = [nala.id, beef.id]
                petDists = [nala.id: p.d * p.nPct, beef.id: p.d * (1 - p.nPct)]
            }

            let tmpl      = demoRouteTemplates[idx % demoRouteTemplates.count]
            let latOff    = Double(idx) * 0.0002
            let lonOff    = Double(idx) * 0.0003
            let waypoints = tmpl.1.map {
                WaypointCoord(CLLocationCoordinate2D(latitude: $0.0 + latOff, longitude: $0.1 + lonOff))
            }

            let routeName: String
            switch p.type {
            case "cycling": routeName = "Bay Trail Ride"
            case "running": routeName = "Hill Repeats"
            default:        routeName = walkNames[idx % walkNames.count]
            }

            sessions.append(WalkSession(
                id: UUID(), routeName: routeName, date: date,
                elapsedTime: elapsed, totalDistance: p.d,
                waypoints: waypoints, lapCount: 1, isLoop: false,
                activePetIds: petIds, activityType: p.type,
                notes: demoTag, petDistances: petDists, steps: steps
            ))
        }

        history.addAll(sessions)
    }

    static func clearScreenshotDemo(history: WalkHistoryStore, pets petStore: PetStore, routes: CustomRouteStore) {
        let sessionIndices = IndexSet(
            history.sessions.enumerated()
                .filter { $0.element.notes == demoTag }
                .map(\.offset)
        )
        if !sessionIndices.isEmpty { history.delete(at: sessionIndices) }

        for name in demoPetNames {
            if let pet = petStore.pets.first(where: { $0.name == name }) {
                petStore.remove(id: pet.id)
            }
        }

        let routeIndices = IndexSet(
            routes.routes.enumerated()
                .filter { demoRouteNames.contains($0.element.name) }
                .map(\.offset)
        )
        if !routeIndices.isEmpty { routes.delete(at: routeIndices) }
    }

    // MARK: - Helpers

    private static func session(name: String, date: Date, distance: Double) -> WalkSession {
        WalkSession(
            id: UUID(), routeName: name, date: date,
            elapsedTime: distance / 1.35,
            totalDistance: distance, waypoints: [],
            lapCount: 1, isLoop: false
        )
    }
}
#endif
