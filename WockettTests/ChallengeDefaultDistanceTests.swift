import Foundation
import Testing
@testable import PoCSquat

/// Create Challenge, Distance (2026-10-12): the default was 10,000 m in every
/// locale, which matches none of the mile options, so in US units no option
/// was highlighted and Create made a 6.2 mi challenge nobody picked.
@Suite struct ChallengeDefaultDistanceTests {
    @Test(arguments: ["en_US", "en_GB", "fr_FR", "en_CA"])
    func defaultIsOneOfTheOptionsShown(identifier: String) {
        let locale = Locale(identifier: identifier)
        let options = CreateChallengeView.distanceOptions(for: locale).map(\.meters)
        #expect(options.contains(CreateChallengeView.defaultDistanceMeters(for: locale)))
    }

    @Test func metricDefaultStaysTenKilometres() {
        #expect(CreateChallengeView.defaultDistanceMeters(for: Locale(identifier: "en_GB")) == 10_000)
    }

    @Test func usDefaultIsSixMiles() {
        #expect(CreateChallengeView.defaultDistanceMeters(for: Locale(identifier: "en_US")) == 9_656)
    }
}
