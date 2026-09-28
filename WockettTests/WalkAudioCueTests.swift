import Testing
import Foundation
@testable import PoCSquat

/// The unit rules behind spoken milestones. These are the pure helpers
/// `WalkAudioCueService.update` is built from; the synthesizer and the audio
/// session are not exercised here.
struct WalkAudioCueTests {

    // MARK: - Milestone counter

    @Test func usPhone_announcesAtOneMile_notAtOneKilometer() {
        // The 1.13 bug: the counter ticked at 1000 m and then said "1 mile".
        #expect(WalkAudioCueService.unitsCovered(meters: 1000, usesMiles: true) == 0)
        #expect(WalkAudioCueService.unitsCovered(meters: 1609.344, usesMiles: true) == 1)
        #expect(WalkAudioCueService.unitsCovered(meters: 3218.7, usesMiles: true) == 2)
    }

    @Test func metricPhone_announcesEveryKilometer() {
        #expect(WalkAudioCueService.unitsCovered(meters: 999, usesMiles: false) == 0)
        #expect(WalkAudioCueService.unitsCovered(meters: 1000, usesMiles: false) == 1)
        #expect(WalkAudioCueService.unitsCovered(meters: 2500, usesMiles: false) == 2)
    }

    // MARK: - Spoken text

    @Test func milestoneText_namesTheUnitAndPluralisesIt() {
        #expect(WalkAudioCueService.milestoneText(units: 1, usesMiles: true) == "1 mile completed.")
        #expect(WalkAudioCueService.milestoneText(units: 2, usesMiles: true) == "2 miles completed.")
        #expect(WalkAudioCueService.milestoneText(units: 1, usesMiles: false) == "1 kilometer completed.")
        #expect(WalkAudioCueService.milestoneText(units: 3, usesMiles: false) == "3 kilometers completed.")
    }

    @Test func pace_isConvertedToPerMileInTheUS() {
        // 6:00 per kilometre is 9:39 per mile (360 s × 1.609344 = 579.36 s).
        #expect(WalkAudioCueService.paceText(secsPerKm: 360, usesMiles: true)
                == "Current pace: 9 minutes 39 seconds per mile.")
    }

    @Test func pace_staysPerKilometerElsewhere_andDropsZeroSeconds() {
        #expect(WalkAudioCueService.paceText(secsPerKm: 360, usesMiles: false)
                == "Current pace: 6 minutes per kilometer.")
        #expect(WalkAudioCueService.paceText(secsPerKm: 372, usesMiles: false)
                == "Current pace: 6 minutes 12 seconds per kilometer.")
    }
}
