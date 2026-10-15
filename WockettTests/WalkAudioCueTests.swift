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

    // The spoken text is tested in RunPacingTests: since 2026-10-14 a cue is
    // said per split and names its average "Average pace", not "Current
    // pace" (`feat/run-pace-splits`).
}
