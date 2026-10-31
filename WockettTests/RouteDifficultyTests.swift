import Testing
import CoreLocation
@testable import PoCSquat

/// A profiled route's difficulty and the line that says why (spec
/// fix/route-detail-hierarchy, Part 1, item 4). Expectations are worked out
/// by hand from the thresholds: expert at 500 m of climb or a grade over
/// 25 %; hard at 15 km, 300 m or over 15 %; moderate at 5 km or 100 m.
struct RouteDifficultyTests {
    private func classify(length: Double = 0, climb: Double = 0, steepest: Double = 0) -> (RouteDifficulty, RouteDifficulty.Reason) {
        RouteDifficulty.classify(lengthMeters: length, climbMeters: climb, steepestPercent: steepest)
    }

    @Test func eachLevelAtAndJustBelowItsBoundary() {
        // Expert
        #expect(classify(climb: 500) == (.expert, .climb(meters: 500)))
        #expect(classify(climb: 499.9) == (.hard, .climb(meters: 499.9)))
        #expect(classify(steepest: 25.1) == (.expert, .steepness(percent: 25.1)))
        #expect(classify(steepest: 25) == (.hard, .steepness(percent: 25)))
        // Hard
        #expect(classify(length: 15_000) == (.hard, .length))
        #expect(classify(length: 14_999) == (.moderate, .length))
        #expect(classify(climb: 300) == (.hard, .climb(meters: 300)))
        #expect(classify(climb: 299.9) == (.moderate, .climb(meters: 299.9)))
        #expect(classify(steepest: 15.1) == (.hard, .steepness(percent: 15.1)))
        #expect(classify(steepest: 15) == (.easy, .nothingMuch))
        // Moderate
        #expect(classify(length: 5_000) == (.moderate, .length))
        #expect(classify(length: 4_999) == (.easy, .nothingMuch))
        #expect(classify(climb: 100) == (.moderate, .climb(meters: 100)))
        #expect(classify(climb: 99.9) == (.easy, .nothingMuch))
    }

    @Test func theReasonNamesTheDecidingInput() {
        // Climb beats length when both qualify for the same level.
        #expect(classify(length: 16_000, climb: 320) == (.hard, .climb(meters: 320)))
        #expect(classify(length: 6_000, climb: 150) == (.moderate, .climb(meters: 150)))
        // Climb beats steepness when both qualify for the same level.
        #expect(classify(climb: 320, steepest: 16) == (.hard, .climb(meters: 320)))
        #expect(classify(climb: 520, steepest: 26) == (.expert, .climb(meters: 520)))
        // A higher level's input wins over a lower level's.
        #expect(classify(length: 16_000, climb: 120) == (.hard, .length))
        #expect(classify(length: 6_000, steepest: 27) == (.expert, .steepness(percent: 27)))
    }

    @Test func whyLines() {
        #expect(RouteDifficulty.hard.why(.climb(meters: 320.6)) == "Hard because of 320 m of climb")
        #expect(RouteDifficulty.expert.why(.steepness(percent: 26.2)) == "Expert because one part is 27 % steep")
        // Rounded up: over 25 % never reads "25 %", which is still Hard.
        #expect(RouteDifficulty.expert.why(.steepness(percent: 25.4)) == "Expert because one part is 26 % steep")
        #expect(RouteDifficulty.moderate.why(.length) == "Moderate because of its length")
        #expect(RouteDifficulty.easy.why(.nothingMuch) == "Easy: short, with little climb")
    }

    /// `buildProfile` decides through `classify`, so the two never disagree.
    /// Each case sits between its threshold and a nearby value, so a
    /// threshold kept in `buildProfile` but changed in `classify` (or the
    /// reverse) shows up here.
    @Test(arguments: [
        (2_000.0, 0.0, false, RouteDifficulty.easy),   // flat and short
        (6_000.0, 0.0, false, .moderate),   // by length
        (16_000.0, 0.0, false, .hard),      // by length
        (2_000.0, 150.0, false, .moderate), // by climb
        (3_000.0, 350.0, false, .hard),     // by climb
        (4_000.0, 550.0, false, .expert),   // by climb
        (1_000.0, 20.0, true, .hard),       // one 20 % part
        (1_000.0, 30.0, true, .expert)      // one 30 % part
    ])
    func buildProfileAgreesWithClassify(length: Double, climb: Double, oneSteepPart: Bool, level: RouteDifficulty) {
        // Points 100 m apart along a meridian; the climb is spread evenly,
        // or put on one 100 m part.
        let parts = Int(length / 100)
        let step = 100 / 111_195.0
        let coordinates = (0...parts).map { CLLocationCoordinate2D(latitude: 35 + Double($0) * step, longitude: -78.6) }
        let elevations = (0...parts).map { i -> Double in
            oneSteepPart ? (i == 0 ? 0 : climb) : climb * Double(i) / Double(parts)
        }
        let profile = ElevationService.buildProfile(elevations: elevations, coordinates: coordinates)
        let expected = RouteDifficulty.classify(lengthMeters: (profile.points.last?.distanceKm ?? 0) * 1_000,
                                                climbMeters: profile.totalGainMeters,
                                                steepestPercent: profile.steepestPercent)
        #expect(profile.difficulty == expected.0)
        #expect(profile.difficulty == level)
        #expect(profile.difficultyReason == expected.1)
        #expect(abs(profile.totalGainMeters - climb) < 0.001)
    }
}
