import Testing
import Foundation
import SwiftData
@testable import PoCSquat

/// Current pace and automatic splits (`feat/run-pace-splits`). The rules are
/// in `RunPacing.swift`.
struct RunPacingTests {

    /// Feeds a steady speed: a fix every `every` seconds from `from` to `to`.
    private func steady(_ pace: inout RollingPace, metersPerSecond: Double,
                        from: TimeInterval = 0, to: TimeInterval, every: TimeInterval = 5,
                        startDistance: Double = 0) -> Double {
        var distance = startDistance
        var t = from
        while t <= to {
            pace.add(elapsed: t, distance: distance)
            distance += metersPerSecond * every
            t += every
        }
        return distance - metersPerSecond * every
    }

    // MARK: - Rolling pace

    @Test func steadyRun_currentPaceIsThatSpeed() throws {
        var pace = RollingPace()
        _ = steady(&pace, metersPerSecond: 3, to: 120)
        // 3 m/s is 333.3 s per km.
        let value = try #require(pace.secsPerKm(at: 120))
        #expect(abs(value - 1000.0 / 3) < 0.5)
    }

    @Test func currentPace_followsTheLastWindow_notTheWholeRun() throws {
        var pace = RollingPace()
        // A slow minute, then a fast one: the average sits between them,
        // the current pace is the fast one alone.
        let d = steady(&pace, metersPerSecond: 2, to: 60)
        _ = steady(&pace, metersPerSecond: 4, from: 65, to: 120, startDistance: d + 20)
        let value = try #require(pace.secsPerKm(at: 120))
        #expect(abs(value - 250) < 1)
    }

    @Test func tooLittleTime_noCurrentPace() {
        var pace = RollingPace()
        _ = steady(&pace, metersPerSecond: 3, to: 15)
        #expect(pace.secsPerKm(at: 15) == nil)
    }

    @Test func tooLittleDistance_noCurrentPace() {
        var pace = RollingPace()
        // 0.5 m/s for 45 s is 22.5 m, under the 30 m minimum.
        _ = steady(&pace, metersPerSecond: 0.5, to: 120)
        #expect(pace.secsPerKm(at: 120) == nil)
    }

    @Test func standingStill_noCurrentPace_afterFifteenSeconds() {
        var pace = RollingPace()
        _ = steady(&pace, metersPerSecond: 3, to: 100)
        #expect(pace.secsPerKm(at: 114) != nil)
        #expect(pace.secsPerKm(at: 116) == nil)
    }

    @Test func windowStart_isInterpolatedBetweenFixes() throws {
        var pace = RollingPace()
        // Fixes 30 s apart; the window starts at 75 s, halfway between the
        // 60 s and 90 s fixes, so its distance there is halfway too. The two
        // stretches run at different speeds, so taking either fix instead of
        // interpolating gives another answer (333.3 or 500, not 375): the
        // first version of this test ran at one speed and could not fail
        // (critic, 2026-10-14).
        pace.add(elapsed: 0, distance: 0)
        pace.add(elapsed: 30, distance: 60)
        pace.add(elapsed: 60, distance: 120)
        pace.add(elapsed: 90, distance: 240)
        pace.add(elapsed: 120, distance: 300)
        // At 75 s: 120 + 0.5 × 120 = 180 m. 45 s for 120 m is 375 s/km.
        let value = try #require(pace.secsPerKm(at: 120))
        #expect(abs(value - 375) < 0.01)
    }

    // MARK: - Split tracker

    @Test func split_timeIsInterpolatedAtTheCrossing() {
        var tracker = SplitTracker(unitMeters: 1000)
        #expect(tracker.add(elapsed: 100, distance: 900).isEmpty)
        let done = tracker.add(elapsed: 120, distance: 1100)
        #expect(done == [UnitSplit(distance: 1000, elapsed: 110)])
    }

    @Test func split_isRecordedOncePerUnit() {
        var tracker = SplitTracker(unitMeters: 1000)
        _ = tracker.add(elapsed: 100, distance: 1010)
        #expect(tracker.add(elapsed: 105, distance: 1020).isEmpty)
        #expect(tracker.splits.count == 1)
    }

    @Test func aJumpOverTwoUnits_recordsBoth() {
        var tracker = SplitTracker(unitMeters: 1000)
        _ = tracker.add(elapsed: 100, distance: 500)
        let done = tracker.add(elapsed: 300, distance: 2500)
        #expect(done.map(\.distance) == [1000, 2000])
        #expect(done.map(\.elapsed) == [150, 250])
    }

    @Test func splitUnit_followsTheLocale() {
        #expect(NavigationSessionManager.splitUnitMeters(locale: Locale(identifier: "en_US")) == 1609.344)
        #expect(NavigationSessionManager.splitUnitMeters(locale: Locale(identifier: "en_CA")) == 1000)
    }

    @Test func onlyWalksAndRuns_haveCurrentPaceAndSplits() {
        #expect(ActivityMode.walking.hasPaceAndSplits)
        #expect(ActivityMode.running.hasPaceAndSplits)
        #expect(!ActivityMode.cycling.hasPaceAndSplits)
        #expect(!ActivityMode.stationary.hasPaceAndSplits)
    }

    @Test func miles_splitAtOneMile() {
        var tracker = SplitTracker(unitMeters: WalkAudioCueService.metersPerMile)
        #expect(tracker.add(elapsed: 500, distance: 1500).isEmpty)
        #expect(tracker.add(elapsed: 600, distance: 1700).count == 1)
    }

    @Test func finished_keepsAPartUnitOfATenthOrMore() throws {
        var tracker = SplitTracker(unitMeters: 1000)
        _ = tracker.add(elapsed: 300, distance: 1000)
        let kept = try #require(tracker.finished(elapsed: 360, distance: 1101))
        #expect(kept.splits.count == 2)
        #expect(kept.splits.last == UnitSplit(distance: 1101, elapsed: 360))
        let dropped = try #require(tracker.finished(elapsed: 330, distance: 1099))
        #expect(dropped.splits.count == 1)
    }

    @Test func finished_isNilWithNothingToShow() {
        let tracker = SplitTracker(unitMeters: 1000)
        #expect(tracker.finished(elapsed: 30, distance: 50) == nil)
    }

    @Test func restored_withSplits_doesNotRecordThemAgain() {
        let saved = UnitSplits(unitMeters: 1000, splits: [UnitSplit(distance: 1000, elapsed: 300)])
        var tracker = SplitTracker(restoring: saved, unitMeters: 1000, elapsed: 400, distance: 1300)
        #expect(tracker.isTracking)
        #expect(tracker.add(elapsed: 410, distance: 1340).isEmpty)
        #expect(tracker.add(elapsed: 600, distance: 2000).map(\.distance) == [2000])
        #expect(tracker.splits.count == 2)
    }

    @Test func restored_fromACheckpointWithoutSplits_pastAUnit_recordsNone() {
        // A checkpoint from before 1.17: the first unit's time is unknown, so
        // no splits rather than a wrong one.
        var tracker = SplitTracker(restoring: nil, unitMeters: 1000, elapsed: 400, distance: 1500)
        #expect(!tracker.isTracking)
        #expect(tracker.add(elapsed: 600, distance: 2100).isEmpty)
        #expect(tracker.finished(elapsed: 600, distance: 2100) == nil)
    }

    @Test func restored_fromACheckpointWithoutSplits_beforeAUnit_keepsTracking() {
        var tracker = SplitTracker(restoring: nil, unitMeters: 1000, elapsed: 200, distance: 600)
        #expect(tracker.isTracking)
        #expect(tracker.add(elapsed: 300, distance: 1000).count == 1)
    }

    // MARK: - Voice cue

    @Test func cue_walkOrRun_namesEachPaceForWhatItIs() {
        let text = WalkAudioCueService.splitCueText(split: 2, unitMeters: WalkAudioCueService.metersPerMile,
                                                    elapsed: 1120, splitSeconds: 552, mode: .running)
        #expect(text == "Mile 2. Time 18 minutes 40 seconds. Last mile 9 minutes 12 seconds. "
                      + "Average pace 9 minutes 20 seconds per mile.")
        #expect(!text.contains("Current"))
    }

    @Test func cue_metric_saysKilometer() {
        let text = WalkAudioCueService.splitCueText(split: 1, unitMeters: 1000,
                                                    elapsed: 360, splitSeconds: 360, mode: .walking)
        #expect(text == "Kilometer 1. Time 6 minutes. Last kilometer 6 minutes. Average pace 6 minutes per kilometer.")
    }

    @Test func cue_ride_saysAverageSpeed_notPace() {
        let text = WalkAudioCueService.splitCueText(split: 4, unitMeters: WalkAudioCueService.metersPerMile,
                                                    elapsed: 960, splitSeconds: 240, mode: .cycling)
        #expect(text == "Mile 4. Time 16 minutes. Average speed 15.0 miles per hour.")
    }

    @Test func spokenDuration_dropsZeroParts() {
        #expect(WalkAudioCueService.spokenDuration(40) == "40 seconds")
        #expect(WalkAudioCueService.spokenDuration(61) == "1 minute 1 second")
        #expect(WalkAudioCueService.spokenDuration(3725) == "1 hour 2 minutes 5 seconds")
        #expect(WalkAudioCueService.spokenDuration(0) == "0 seconds")
    }

    // MARK: - Summary rows

    @Test func splitRows_wholeUnitsAndAPartUnit() {
        let splits = UnitSplits(unitMeters: WalkAudioCueService.metersPerMile, splits: [
            UnitSplit(distance: 1609.344, elapsed: 552),
            UnitSplit(distance: 3218.688, elapsed: 1120),
            UnitSplit(distance: 3910.68, elapsed: 1380)
        ])
        let rows = ActivitySummaryContent.splitRows(splits)
        #expect(rows.map(\.label) == ["Mile 1", "Mile 2", "0.43 mi"])
        #expect(rows.map(\.time) == ["9:12", "9:28", "4:20"])
        #expect(rows[0].pace == "9:12/mi")
        #expect(rows[1].pace == "9:28/mi")
    }

    @Test func splitRows_metric() {
        let splits = UnitSplits(unitMeters: 1000, splits: [UnitSplit(distance: 1000, elapsed: 330)])
        let rows = ActivitySummaryContent.splitRows(splits)
        #expect(rows == [.init(label: "Km 1", time: "5:30", pace: "5:30/km")])
    }

    @Test func splitRows_noneForAnActivityWithout() {
        #expect(ActivitySummaryContent.splitRows(nil).isEmpty)
    }

    // MARK: - Saved with the activity

    @Test func walkSession_roundTripsSplits_throughItsRecord() {
        let splits = UnitSplits(unitMeters: 1000, splits: [UnitSplit(distance: 1000, elapsed: 330)])
        let session = WalkSession(id: UUID(), routeName: "Run", date: Date(), elapsedTime: 400,
                                  totalDistance: 1200, waypoints: [], lapCount: 1, isLoop: false,
                                  activityType: "running", unitSplits: splits)
        #expect(WalkSessionRecord(from: session).toWalkSession().unitSplits == splits)
    }

    @Test func recordFromBefore117_hasNoSplits() {
        let session = WalkSession(id: UUID(), routeName: "Walk", date: Date(), elapsedTime: 400,
                                  totalDistance: 1200, waypoints: [], lapCount: 1, isLoop: false)
        let record = WalkSessionRecord(from: session)
        record.unitSplitsData = Data()   // the field's default on an old record
        #expect(record.toWalkSession().unitSplits == nil)
    }

    @Test func codableSessionFromBefore117_decodesWithNoSplits() throws {
        let session = WalkSession(id: UUID(), routeName: "Walk", date: Date(), elapsedTime: 400,
                                  totalDistance: 1200, waypoints: [], lapCount: 1, isLoop: false,
                                  unitSplits: UnitSplits(unitMeters: 1000, splits: []))
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        json.removeValue(forKey: "unitSplits")
        let old = try JSONDecoder().decode(WalkSession.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.unitSplits == nil)
    }

    // MARK: - Session manager

    private func route(_ mode: ActivityMode) -> NavigableRoute {
        NavigableRoute(name: "Free", waypoints: [], lapCount: 1, isLoop: false,
                       totalDistance: 0, activityMode: mode)
    }

    /// Drives a session at a steady speed through `recordPacing`, as fixes would.
    @MainActor private func drive(_ mgr: NavigationSessionManager, metersPerSecond: Double, to: TimeInterval) {
        mgr.writesSnapshots = false
        mgr.speaksSplits = false
        var t: TimeInterval = 0
        while t <= to {
            mgr.elapsedTime = t
            mgr.totalDistanceCovered = metersPerSecond * t
            mgr.recordPacing()
            t += 5
        }
    }

    @Test @MainActor func run_isSavedWithItsSplits() throws {
        let mgr = NavigationSessionManager(route: route(.running))
        let unit = mgr.splitTracker.unitMeters
        drive(mgr, metersPerSecond: 3, to: (unit * 2.5) / 3)
        let splits = try #require(mgr.completedSession.unitSplits)
        #expect(splits.splits.count == 3)   // two whole units and the half after
        #expect(splits.unitMeters == unit)
    }

    @Test @MainActor func ride_isSavedWithoutSplits_andHasNoCurrentPace() {
        let mgr = NavigationSessionManager(route: route(.cycling))
        drive(mgr, metersPerSecond: 6, to: 600)
        #expect(mgr.completedSession.unitSplits == nil)
        #expect(mgr.currentPaceSecsPerKm == nil)
        #expect(mgr.paceLabel == "speed")
    }

    @Test @MainActor func walk_hasACurrentPace_andLabelsItsAverage() throws {
        let mgr = NavigationSessionManager(route: route(.walking))
        drive(mgr, metersPerSecond: 1.4, to: 120)
        let current = try #require(mgr.currentPaceSecsPerKm)
        #expect(abs(current - 1000 / 1.4) < 1)
        #expect(mgr.paceLabel == "avg pace")
        #expect(mgr.liveActivityState.currentPaceSecsPerKm == current)
        #expect(mgr.liveActivityState.paceSecsPerKm == mgr.averagePaceSecsPerKm)
    }

    @Test @MainActor func splits_surviveACrashRestore() throws {
        let mgr = NavigationSessionManager(route: route(.running))
        let unit = mgr.splitTracker.unitMeters
        drive(mgr, metersPerSecond: 3, to: (unit * 1.5) / 3)
        let snapshot = mgr.snapshot
        #expect(snapshot.unitSplits?.splits.count == 1)

        let data = try JSONEncoder().encode(snapshot)
        let restored = NavigationSessionManager(route: route(.running))
        restored.writesSnapshots = false
        restored.speaksSplits = false
        restored.applySnapshot(try JSONDecoder().decode(ActiveWalkSnapshot.self, from: data))
        #expect(restored.splitTracker.splits == mgr.splitTracker.splits)
        #expect(restored.splitTracker.isTracking)
    }

    @Test @MainActor func aCompletedSplit_isCheckpointedAtOnce() {
        // A killed app restores to its last checkpoint; one taken only every
        // 15 s could predate a split already spoken, which would be said again.
        let mgr = NavigationSessionManager(route: route(.running))
        mgr.writesSnapshots = false
        mgr.speaksSplits = false
        let unit = mgr.splitTracker.unitMeters
        mgr.elapsedTime = 300; mgr.totalDistanceCovered = unit - 10
        mgr.recordPacing()
        let before = mgr.checkpointRequests
        mgr.elapsedTime = 305; mgr.totalDistanceCovered = unit - 1
        mgr.recordPacing()
        #expect(mgr.checkpointRequests == before)
        mgr.elapsedTime = 310; mgr.totalDistanceCovered = unit + 10
        mgr.recordPacing()
        #expect(mgr.checkpointRequests == before + 1)
        #expect(mgr.snapshot.unitSplits?.splits.count == 1)
    }

    @Test @MainActor func theSecondTick_pushesWhenCurrentPaceLapses() {
        // The timer's own path, not the refresh alone: removing the call
        // from secondTick() must turn this red.
        let mgr = NavigationSessionManager(route: route(.running))
        drive(mgr, metersPerSecond: 3, to: 100)
        mgr.secondTick()
        #expect(mgr.lastPushedHadCurrentPace)
        mgr.elapsedTime = 116
        mgr.secondTick()
        #expect(!mgr.lastPushedHadCurrentPace)
    }

    @Test @MainActor func ride_speedTile_keepsItsFiftyMetreStart() {
        let mgr = NavigationSessionManager(route: route(.cycling))
        mgr.elapsedTime = 8; mgr.totalDistanceCovered = 60
        #expect(mgr.paceText != "--")
    }

    @Test @MainActor func standingStill_pushesTheLiveActivityOnce_whenCurrentPaceLapses() {
        // Standing still brings no fixes, so the 1 s timer is what tells the
        // Lock Screen current pace has gone; it pushes only on the change.
        let mgr = NavigationSessionManager(route: route(.running))
        drive(mgr, metersPerSecond: 3, to: 100)
        #expect(mgr.refreshLiveActivityIfCurrentPaceChanged())     // first pace to show
        #expect(mgr.lastPushedHadCurrentPace)
        mgr.elapsedTime = 110
        #expect(!mgr.refreshLiveActivityIfCurrentPaceChanged())    // still moving, as far as it knows
        mgr.elapsedTime = 116
        #expect(mgr.refreshLiveActivityIfCurrentPaceChanged())     // 16 s without a fix
        #expect(!mgr.lastPushedHadCurrentPace)
        mgr.elapsedTime = 130
        #expect(!mgr.refreshLiveActivityIfCurrentPaceChanged())    // no push every second
    }

    // MARK: - Salvaged walks

    @MainActor private func checkpoint(_ mode: ActivityMode, units: Double, withSplits: Bool = true) throws -> ActiveWalkSnapshot {
        let mgr = NavigationSessionManager(route: route(mode))
        let unit = mgr.splitTracker.unitMeters
        drive(mgr, metersPerSecond: 3, to: (unit * units) / 3)
        let data = try JSONEncoder().encode(mgr.snapshot)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        if !withSplits { json.removeValue(forKey: "unitSplits") }
        return try JSONDecoder().decode(ActiveWalkSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test @MainActor func salvagedRun_keepsItsWholeUnitsAndThePartAfter() throws {
        let snapshot = try checkpoint(.running, units: 1.5)
        let splits = try #require(ActiveWalkStore.salvagedSplits(for: snapshot, elapsed: 500))
        #expect(splits.splits.count == 2)
        #expect(splits.splits.last?.elapsed == 500)
    }

    @Test @MainActor func salvagedRide_keepsNoSplits() throws {
        let snapshot = try checkpoint(.cycling, units: 1.5)
        #expect(snapshot.unitSplits != nil)   // the ride's tracker ran, for its cue
        #expect(ActiveWalkStore.salvagedSplits(for: snapshot, elapsed: 500) == nil)
    }

    @Test @MainActor func salvagedCheckpointFromBefore117_keepsNoSplits() throws {
        let snapshot = try checkpoint(.running, units: 1.5, withSplits: false)
        #expect(ActiveWalkStore.salvagedSplits(for: snapshot, elapsed: 500) == nil)
    }

    @Test @MainActor func checkpointFromBefore117_decodesWithNoSplits() throws {
        let mgr = NavigationSessionManager(route: route(.running))
        drive(mgr, metersPerSecond: 3, to: 100)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(mgr.snapshot)) as? [String: Any])
        json.removeValue(forKey: "unitSplits")
        let old = try JSONDecoder().decode(ActiveWalkSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.unitSplits == nil)
    }
}
