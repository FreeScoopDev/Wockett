import Testing
import Foundation
@testable import PoCSquat

/// The untracked-walk nudge decides, after the fact, whether to interrupt someone
/// about a walk they already finished. Everything that makes that decision is a
/// pure function, and these are the thresholds that keep it from being annoying.
struct UntrackedWalkPolicyTests {

    private let start = Date(timeIntervalSince1970: 1_757_000_000)
    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    private func window(activeMinutes: Double, metres: Double, kind: MotionSample.Kind = .walking) -> ActivityWindow {
        ActivityWindow(activeSeconds: activeMinutes * 60, distanceMeters: metres, dominant: kind)
    }

    // MARK: summarize

    @Test func aSampleLastsUntilTheNextOneAndTheLastUntilTheEnd() {
        let samples = [
            MotionSample(start: at(0),  kind: .walking, isHighConfidence: true),
            MotionSample(start: at(10), kind: .other,   isHighConfidence: true),
            MotionSample(start: at(15), kind: .walking, isHighConfidence: true)
        ]
        let result = UntrackedWalkPolicy.summarize(samples, endingAt: at(20))
        #expect(result.activeSeconds == 15 * 60)   // 0–10 plus 15–20; the `other` gap is not movement
        #expect(result.dominant == .walking)
    }

    @Test func lowConfidenceSamplesDoNotCount() {
        let samples = [
            MotionSample(start: at(0),  kind: .walking, isHighConfidence: false),
            MotionSample(start: at(20), kind: .walking, isHighConfidence: true)
        ]
        let result = UntrackedWalkPolicy.summarize(samples, endingAt: at(30))
        #expect(result.activeSeconds == 10 * 60)
    }

    @Test func theDominantKindIsWhicheverLastedLongest() {
        let samples = [
            MotionSample(start: at(0),  kind: .walking, isHighConfidence: true),   // 5 min
            MotionSample(start: at(5),  kind: .cycling, isHighConfidence: true),   // 25 min
            MotionSample(start: at(30), kind: .running, isHighConfidence: true)    // 2 min
        ]
        let result = UntrackedWalkPolicy.summarize(samples, endingAt: at(32))
        #expect(result.dominant == .cycling)
        #expect(result.activeSeconds == 32 * 60)
    }

    @Test func unorderedSamplesAreSortedFirst() {
        let jumbled = [
            MotionSample(start: at(20), kind: .walking, isHighConfidence: true),
            MotionSample(start: at(0),  kind: .walking, isHighConfidence: true)
        ]
        #expect(UntrackedWalkPolicy.summarize(jumbled, endingAt: at(30)).activeSeconds == 30 * 60)
    }

    @Test func noSamplesIsNoActivity() {
        let result = UntrackedWalkPolicy.summarize([], endingAt: at(30))
        #expect(result.activeSeconds == 0)
        #expect(result.dominant == .other)
    }

    // MARK: shouldNotify

    @Test func aRealWalkQualifies() {
        #expect(UntrackedWalkPolicy.shouldNotify(window: window(activeMinutes: 20, metres: 1_600),
                                                 isSessionActive: false, lastNotified: nil, now: start))
    }

    @Test func pacingIndoorsDoesNotQualify() {
        // Twenty minutes of "walking" but barely any ground covered — a shop, a kitchen.
        #expect(UntrackedWalkPolicy.shouldNotify(window: window(activeMinutes: 20, metres: 120),
                                                 isSessionActive: false, lastNotified: nil, now: start) == false)
    }

    @Test func aShortBurstDoesNotQualifyHoweverFar() {
        #expect(UntrackedWalkPolicy.shouldNotify(window: window(activeMinutes: 4, metres: 3_000),
                                                 isSessionActive: false, lastNotified: nil, now: start) == false)
    }

    @Test func thresholdsAreInclusive() {
        let exact = window(activeMinutes: UntrackedWalkPolicy.minimumActiveSeconds / 60,
                           metres: UntrackedWalkPolicy.minimumDistanceMeters)
        #expect(UntrackedWalkPolicy.shouldNotify(window: exact, isSessionActive: false, lastNotified: nil, now: start))
    }

    @Test func aTrackedWalkIsNeverNudgedAbout() {
        #expect(UntrackedWalkPolicy.shouldNotify(window: window(activeMinutes: 30, metres: 2_500),
                                                 isSessionActive: true, lastNotified: nil, now: start) == false)
    }

    @Test func atMostOneNudgePerDay() {
        let big = window(activeMinutes: 30, metres: 2_500)
        let recent = start.addingTimeInterval(-3 * 3600)
        #expect(UntrackedWalkPolicy.shouldNotify(window: big, isSessionActive: false,
                                                 lastNotified: recent, now: start) == false)
        let yesterday = start.addingTimeInterval(-25 * 3600)
        #expect(UntrackedWalkPolicy.shouldNotify(window: big, isSessionActive: false,
                                                 lastNotified: yesterday, now: start))
    }

    // MARK: copy

    @Test func titleNamesWhatTheyActuallyDid() {
        #expect(UntrackedWalkPolicy.title(for: window(activeMinutes: 20, metres: 2_000, kind: .running)) == "You went for a run")
        #expect(UntrackedWalkPolicy.title(for: window(activeMinutes: 20, metres: 2_000, kind: .cycling)) == "You went for a ride")
        #expect(UntrackedWalkPolicy.title(for: window(activeMinutes: 20, metres: 2_000, kind: .walking)) == "You went for a walk")
    }

    @Test func bodyStatesDistanceAndTimeOfDayInTheReadersUnits() {
        let cal = Calendar(identifier: .gregorian)
        let morning = cal.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 9))!
        let metric = UntrackedWalkPolicy.body(for: window(activeMinutes: 20, metres: 1_800),
                                              now: morning, locale: Locale(identifier: "en_GB"), calendar: cal)
        #expect(metric == "About 1.8 km this morning, untracked. Want to track the next one?")

        let evening = cal.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 19))!
        let imperial = UntrackedWalkPolicy.body(for: window(activeMinutes: 20, metres: 1_609.34),
                                                now: evening, locale: Locale(identifier: "en_US"), calendar: cal)
        #expect(imperial == "About 1.0 mi this evening, untracked. Want to track the next one?")
    }
}
