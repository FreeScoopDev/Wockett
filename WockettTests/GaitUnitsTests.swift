import Testing
@testable import PoCSquat

/// Walking speed and step length follow the phone's units (2026-10-07); they
/// were km/h and cm even on a US phone.
@Suite struct GaitUnitsTests {
    @Test func walkingSpeed() {
        #expect(GaitMetricConfig.speedText(1.34, usesMiles: true) == "3.0 mph")
        #expect(GaitMetricConfig.speedText(1.34, usesMiles: false) == "4.8 km/h")
    }

    @Test func stepLength() {
        #expect(GaitMetricConfig.stepLengthText(70, usesMiles: true) == "28 in")
        #expect(GaitMetricConfig.stepLengthText(70, usesMiles: false) == "70 cm")
    }
}
