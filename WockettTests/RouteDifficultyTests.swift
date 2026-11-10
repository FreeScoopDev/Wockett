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
        // The climb rounds and follows the unit, like the climb line above it.
        #expect(RouteDifficulty.hard.why(.climb(meters: 320.6), metric: true) == "Hard because of 321 m of climb")
        #expect(RouteDifficulty.moderate.why(.climb(meters: 120.4), metric: false) == "Moderate because of 395 ft of climb")
        #expect(RouteDifficulty.moderate.why(.climb(meters: 120.4), metric: false)
                .contains(RouteElevation.gain(120.4, metric: false).dropFirst()))
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

/// Steepness over a stretch of at least 100 m (spec
/// fix/route-difficulty-steepness). SRTM 90 m heights are whole metres per
/// ~90 m cell, so adjacent samples a few metres apart read a 1 m step as a
/// steep slope; measured over 100 m the same step is 1 %.
struct SteepestGradeTests {
    /// Cumulative distances for `count` samples `spacing` metres apart.
    private func distances(_ count: Int, spacing: Double) -> [Double] {
        (0..<count).map { Double($0) * spacing }
    }

    /// The SRTM pattern: flat ground read as 0 m and 1 m in turn, every
    /// 8 m. Adjacent samples gave 12.5 % here.
    private func srtmNoise(count: Int = 100) -> [Double] {
        (0..<count).map { ($0 / 3) % 2 == 0 ? 100 : 101 }
    }

    @Test func wholeMetreNoiseOnFlatGroundIsNotSteep() {
        let grade = ElevationService.steepestGrade(elevations: srtmNoise(), distances: distances(100, spacing: 8))
        #expect(grade < 5)
    }

    @Test func aSustainedTwentyPercentStretchStillCounts() {
        // Flat for 200 m, then 150 m rising 20 %, then flat; samples every 10 m.
        let d = distances(60, spacing: 10)
        let e = d.map { x -> Double in
            if x <= 200 { return 0 }
            if x <= 350 { return (x - 200) * 0.2 }
            return 30
        }
        let grade = ElevationService.steepestGrade(elevations: e, distances: d)
        #expect(abs(grade - 20) < 0.01)
    }

    @Test func aShortPitchCountsOverTheWholeWindow() {
        // A 50 m pitch rising 15 m (30 %) inside flat ground: over 100 m it
        // is 15 m of climb, so 15 %, not over the Hard threshold.
        let d = distances(40, spacing: 10)
        let e = d.map { x -> Double in x <= 150 ? 0 : (x <= 200 ? (x - 150) * 0.3 : 15) }
        let grade = ElevationService.steepestGrade(elevations: e, distances: d)
        #expect(abs(grade - 15) < 0.01)
    }

    @Test func aRouteShorterThanTheWindowHasNoGrade() {
        let grade = ElevationService.steepestGrade(elevations: [0, 5, 10, 15, 20], distances: distances(5, spacing: 20))
        #expect(grade == 0)
    }

    @Test func emptyAndSinglePointInputs() {
        #expect(ElevationService.steepestGrade(elevations: [], distances: []) == 0)
        #expect(ElevationService.steepestGrade(elevations: [42], distances: [0]) == 0)
    }

    /// The demo's case: a short, flat route sampled every ~6 m with
    /// whole-metre noise. The old adjacent-pair rule read 1 m over 6 m as
    /// 16.7 %, so this was "Hard because one part is 17 % steep".
    @Test func aNoisyFlatShortRouteIsEasy() {
        let step = 6 / 111_195.0
        let coordinates = (0..<100).map { CLLocationCoordinate2D(latitude: 35 + Double($0) * step, longitude: -78.6) }
        let profile = ElevationService.buildProfile(elevations: srtmNoise(), coordinates: coordinates)
        #expect(profile.steepestPercent < 5)
        #expect(profile.difficulty == .easy)
        #expect(profile.difficultyReason == .nothingMuch)
    }
}
