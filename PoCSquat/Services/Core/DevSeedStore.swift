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
