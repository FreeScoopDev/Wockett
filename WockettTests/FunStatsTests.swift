import Testing
import Foundation
@testable import PoCSquat

/// Health → "Your journey in perspective" (`FunStats`, 2026-10-27). The card
/// used to add today's Health steps (double-counting a walk recorded today),
/// give rides distance-derived steps, and keep sessions flagged as possible
/// driving. Expected values are worked out by hand from each fixture.
struct FunStatsTests {

    private let day = Date(timeIntervalSince1970: 1_792_000_000) // fixed: October 2026

    private func session(_ activity: String, meters: Double, steps: Int = 0, seconds: TimeInterval = 1_800,
                         flagged: Bool = false) -> WalkSession {
        var s = WalkSession(id: UUID(), routeName: "Test", date: day, elapsedTime: seconds,
                            totalDistance: meters, waypoints: [], lapCount: 0, isLoop: false,
                            activityType: activity, steps: steps)
        s.flaggedPossibleVehicle = flagged
        return s
    }

    /// walk 5,000 (fallback) + run 6,000 + indoor 1,000 + ride 0 + legacy ride 0 = 12,000 steps;
    /// 3,810 + 5,000 + 762 + 20,000 + 10,000 = 39,572 m.
    private var fixture: [WalkSession] {
        [session("walking", meters: 3_810),
         session("running", meters: 5_000, steps: 6_000),
         session("stationary", meters: 762, steps: 1_000),
         session("cycling", meters: 20_000),
         session("cycling", meters: 10_000, steps: 4_000)]
    }

    @Test("Distance spans every activity; steps leave rides out, saved or not")
    func totalsFromTheFixture() {
        let t = FunStats.totals(fixture)
        #expect(t.steps == 12_000)
        #expect(abs(t.km - 39.572) < 1e-9)
    }

    @Test("Every fact the fixture earns: 14 bridges, no marathon, 7 Empire State climbs, Earth")
    func allFactsFromTheFixture() {
        let facts = FunStats.allFacts(from: fixture)
        #expect(facts.map(\.headline) == ["14 Golden Gate crossings",
                                          "Step count equal to 7 Empire State climbs",
                                          "0.10% around Earth"])
        #expect(facts[0].detail == "Recorded distance, all activities")
        #expect(facts[1].detail == "Estimated steps from walks and runs · 1,576 stairs per climb")
        #expect(facts[2].detail == "Recorded distance, all activities · 40,075 km circumference")
        #expect(FunStats.facts(from: fixture) == Array(facts.prefix(2)))
    }

    @Test("A marathon is a distance equal to one, never one completed")
    func marathonWording() {
        let facts = FunStats.allFacts(from: [session("walking", meters: 42_195)])
        let marathon = facts.first { $0.emoji == "🏅" }
        #expect(marathon?.headline == "Distance equal to 1 marathon")
        #expect(facts.allSatisfy { !$0.headline.contains("completed") })
        #expect(facts.allSatisfy { !$0.headline.contains("up the Empire State") })
    }

    @Test("Ride-only history: distance facts, no step fact")
    func rideOnly() {
        let rides = [session("cycling", meters: 30_000), session("cycling", meters: 15_000, steps: 9_000)]
        #expect(FunStats.totals(rides).steps == 0)
        let facts = FunStats.allFacts(from: rides)
        #expect(facts.map(\.emoji) == ["🌉", "🏅", "🌍"])
    }

    @Test("Sessions flagged as possible driving add nothing")
    func flaggedLeftOut() {
        let sessions = [session("walking", meters: 1_524),
                        session("walking", meters: 40_000, steps: 50_000, flagged: true),
                        session("cycling", meters: 60_000, flagged: true)]
        let t = FunStats.totals(sessions)
        #expect(t.steps == 2_000)
        #expect(abs(t.km - 1.524) < 1e-9)
    }

    @Test("A 100 m, 90 s walk still counts")
    func shortWalkCounts() {
        let t = FunStats.totals([session("walking", meters: 100, seconds: 90)])
        #expect(t.steps == 131) // 100 / 0.762 = 131.2
        #expect(abs(t.km - 0.1) < 1e-9)
    }

    @Test("The same sessions always give the same facts: nothing else is an input")
    func deterministic() {
        #expect(FunStats.allFacts(from: fixture) == FunStats.allFacts(from: fixture))
        #expect(FunStats.facts(from: []).isEmpty)
    }
}
