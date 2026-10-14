import Testing
import Foundation
@testable import PoCSquat

// The Fastest Pace record was fixed per-km, so US walkers saw /km beside
// miles everywhere else; it now follows the locale through
// `challengeFormattedPace`. The indoor walk's pace tile, tested here until
// 2026-10-13, is gone: its distance is only steps times a stride.
@MainActor
struct PaceUnitTests {
    private let us = Locale(identifier: "en_US")
    private let canada = Locale(identifier: "en_CA")

    @Test func fastestPaceRecord_usesMilesInTheUS() {
        #expect(PRType.fastest(secsPerKm: 360, mode: .walking).valueText(locale: us) == "9:39/mi")
    }

    @Test func fastestPaceRecord_usesKilometresInCanada() {
        #expect(PRType.fastest(secsPerKm: 360, mode: .walking).valueText(locale: canada) == "6:00/km")
    }

    // A ride's fastest is a speed: 120 s/km is 30 km/h, 18.6 mph.
    @Test func fastestRideRecord_isASpeedInTheLocalesUnits() {
        #expect(PRType.fastest(secsPerKm: 120, mode: .cycling).valueText(locale: canada) == "30.0 km/h")
        #expect(PRType.fastest(secsPerKm: 120, mode: .cycling).valueText(locale: us) == "18.6 mph")
    }
}
