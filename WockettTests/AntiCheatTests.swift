import Testing
import Foundation
@testable import PoCSquat

// MARK: - StopTracker

struct StopTrackerTests {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// Feeds `seconds` consecutive stationary ticks, one per simulated second,
    /// starting one second after `base`, and returns each tick's event.
    private func stopped(_ tracker: inout StopTracker, seconds: Int, from base: Date) -> [StopTracker.Event?] {
        (1...seconds).map { s in
            tracker.tick(isMoving: false, now: base.addingTimeInterval(TimeInterval(s)))
        }
    }

    @Test func movingNeverIncrementsStopCount() {
        var tracker = StopTracker(breakThresholdSeconds: 180)
        for s in 0..<30 {
            #expect(tracker.tick(isMoving: true, now: start.addingTimeInterval(TimeInterval(s))) == nil)
        }
        #expect(tracker.stopCount == 0)
    }

    @Test func stopCountIncrementsOnceAfter15SecondsStationary() {
        var tracker = StopTracker(breakThresholdSeconds: 180)
        let events = stopped(&tracker, seconds: 20, from: start)
        #expect(events.allSatisfy { $0 == nil })   // well under the 180s break threshold
        #expect(tracker.stopCount == 1)
    }

    @Test func briefStopUnder15SecondsDoesNotCount() {
        var tracker = StopTracker(breakThresholdSeconds: 180)
        _ = stopped(&tracker, seconds: 10, from: start)
        #expect(tracker.stopCount == 0)
    }

    @Test func resumingMovementBeforeThresholdResetsTheStopWindow() {
        var tracker = StopTracker(breakThresholdSeconds: 180)
        _ = stopped(&tracker, seconds: 10, from: start)                              // 10s stopped, not yet counted
        _ = tracker.tick(isMoving: true, now: start.addingTimeInterval(11))          // moves again
        _ = stopped(&tracker, seconds: 10, from: start.addingTimeInterval(11))       // only 10s more, still short
        #expect(tracker.stopCount == 0)
    }

    @Test func multipleSeparateStopsEachCount() {
        var tracker = StopTracker(breakThresholdSeconds: 180)
        _ = stopped(&tracker, seconds: 20, from: start)
        _ = tracker.tick(isMoving: true, now: start.addingTimeInterval(21))
        _ = stopped(&tracker, seconds: 20, from: start.addingTimeInterval(21))
        #expect(tracker.stopCount == 2)
    }

    @Test func breakPromptFiresExactlyOnceAtThreshold() {
        var tracker = StopTracker(breakThresholdSeconds: 180)
        let events = stopped(&tracker, seconds: 200, from: start)
        #expect(events.filter { $0 == .showBreakPrompt }.count == 1)
    }

    @Test func resetAllowsBreakPromptToFireAgain() {
        var tracker = StopTracker(breakThresholdSeconds: 180)
        _ = stopped(&tracker, seconds: 180, from: start)
        #expect(tracker.tick(isMoving: false, now: start.addingTimeInterval(181)) == nil) // already fired once

        tracker.reset()
        let events = stopped(&tracker, seconds: 180, from: start.addingTimeInterval(200))
        #expect(events.contains(.showBreakPrompt))
    }

    @Test func respectsConfigurableThreshold() {
        // e.g. the user set "Break prompt after 1 min" in Settings
        var tracker = StopTracker(breakThresholdSeconds: 60)
        let events = stopped(&tracker, seconds: 65, from: start)
        #expect(events.contains(.showBreakPrompt))
    }
}

// MARK: - DrivingDetector

struct DrivingDetectorTests {

    private let start = Date(timeIntervalSince1970: 2_000_000)
    private let walkingCeiling = 3.5  // ActivityMode.walking's drivingSpeedCeiling

    @Test func speedBelowCeilingNeverTriggers() {
        var detector = DrivingDetector(speedCeiling: walkingCeiling)
        for s in 1...40 {
            #expect(detector.tick(speed: 2.0, isAutomotiveHigh: false, now: start.addingTimeInterval(TimeInterval(s))) == nil)
        }
    }

    @Test func invalidSpeedReadingIsNotTreatedAsSpeeding() {
        // CLLocation.speed reports -1 when the reading is invalid (e.g. no fix yet) -- must not count as "fast".
        var detector = DrivingDetector(speedCeiling: walkingCeiling)
        for s in 1...40 {
            #expect(detector.tick(speed: -1, isAutomotiveHigh: false, now: start.addingTimeInterval(TimeInterval(s))) == nil)
        }
    }

    @Test func sustainedSpeedingTriggersAfterThreshold() {
        var detector = DrivingDetector(speedCeiling: walkingCeiling)
        for s in 1...25 {
            #expect(detector.tick(speed: 10.0, isAutomotiveHigh: false, now: start.addingTimeInterval(TimeInterval(s))) == nil)
        }
        #expect(detector.tick(speed: 10.0, isAutomotiveHigh: false, now: start.addingTimeInterval(26)) == .drivingSuspected)
    }

    @Test func sustainedAutomotiveConfidenceAloneTriggers() {
        // CoreMotion's automotive-high signal should trip the same sustained path even at zero GPS speed.
        var detector = DrivingDetector(speedCeiling: walkingCeiling)
        for s in 1...25 {
            #expect(detector.tick(speed: 0, isAutomotiveHigh: true, now: start.addingTimeInterval(TimeInterval(s))) == nil)
        }
        #expect(detector.tick(speed: 0, isAutomotiveHigh: true, now: start.addingTimeInterval(26)) == .drivingSuspected)
    }

    @Test func secondEpisodeTriggersImmediatelyEvenIfBriefer() {
        var detector = DrivingDetector(speedCeiling: walkingCeiling)

        // First episode: 6s over the ceiling -- long enough to count, well under the 25s sustained window.
        for s in 1...6 {
            #expect(detector.tick(speed: 10.0, isAutomotiveHigh: false, now: start.addingTimeInterval(TimeInterval(s))) == nil)
        }
        #expect(detector.tick(speed: 1.0, isAutomotiveHigh: false, now: start.addingTimeInterval(7)) == nil)

        // Second episode, well after the first: should fire on its very first over-threshold tick.
        #expect(detector.tick(speed: 10.0, isAutomotiveHigh: false, now: start.addingTimeInterval(60)) == .drivingSuspected)
    }

    @Test func subFourSecondBlipDoesNotCountAsAnEpisode() {
        var detector = DrivingDetector(speedCeiling: walkingCeiling)

        // First blip: only 2s over the ceiling -- shorter than the 4s minimum, treated as noise.
        for s in 1...2 {
            #expect(detector.tick(speed: 10.0, isAutomotiveHigh: false, now: start.addingTimeInterval(TimeInterval(s))) == nil)
        }
        #expect(detector.tick(speed: 1.0, isAutomotiveHigh: false, now: start.addingTimeInterval(3)) == nil)

        // A later episode should NOT get the fast "second episode" trigger, since the blip never counted as one.
        for s in 1...25 {
            let event = detector.tick(speed: 10.0, isAutomotiveHigh: false, now: start.addingTimeInterval(TimeInterval(60 + s)))
            #expect(event == nil, "tick \(s) after the noise blip should still require the full sustained window")
        }
    }
}
