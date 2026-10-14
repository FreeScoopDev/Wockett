import Testing
import Foundation
@testable import PoCSquat

// The Fastest Pace record and the indoor walk's pace tile were fixed per-km,
// so US walkers saw /km beside miles everywhere else. Both now follow the
// locale through `challengeFormattedPace`.
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

    // 1,000 steps is 762 m; 600 s over 762 m is 787 s/km, 1,267 s/mi.
    @Test func indoorWalkPace_followsTheLocale() {
        let manager = StationaryWalkManager()
        manager.steps = 1000
        manager.elapsedSeconds = 600
        #expect(manager.paceText(locale: us) == "21:07/mi")
        #expect(manager.paceText(locale: canada) == "13:07/km")
    }
}
