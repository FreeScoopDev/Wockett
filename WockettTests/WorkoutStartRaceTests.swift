import Testing
import CoreLocation
import HealthKit
@testable import PoCSquat

/// A walk's Health workout starts in a task while the walk begins. The writer
/// used to be kept only after `start` returned, so a walk saved or discarded
/// in that window found no writer: nothing reached Health, and the writer that
/// arrived afterwards kept a workout open for good (2026-10-26 review,
/// finding 9).
@MainActor
struct WorkoutStartRaceTests {

    /// Holds `start` until the test releases it, and tells the test when
    /// `finish` or `discard` arrives. Waits are continuations, never polling.
    private final class GatedWriter: WalkWorkoutRecording {
        private(set) var started = false
        private(set) var finishes: [(distance: Double, end: Date)] = []
        private(set) var discards = 0
        private(set) var finishedBeforeStart = false

        private var startWaiting: CheckedContinuation<Void, Never>?
        private var startHeldWaiters: [CheckedContinuation<Void, Never>] = []
        private var terminalWaiters: [CheckedContinuation<Void, Never>] = []

        func start(at date: Date) async {
            await withCheckedContinuation { c in
                startWaiting = c
                let arrived = startHeldWaiters
                startHeldWaiters = []
                arrived.forEach { $0.resume() }
            }
            started = true
        }

        func addLocations(_ locations: [CLLocation]) {}

        func discard() {
            if !started { finishedBeforeStart = true }
            discards += 1
            signalTerminal()
        }

        func finish(totalDistanceMeters: Double, endDate: Date) async -> HKWorkout? {
            if !started { finishedBeforeStart = true }
            finishes.append((totalDistanceMeters, endDate))
            signalTerminal()
            return nil
        }

        func startHeld() async {
            if startWaiting != nil { return }
            await withCheckedContinuation { startHeldWaiters.append($0) }
        }

        func releaseStart() {
            let c = startWaiting
            startWaiting = nil
            c?.resume()
        }

        /// Returns once `finish` or `discard` has been called.
        func terminalCalled() async {
            if discards + finishes.count > 0 { return }
            await withCheckedContinuation { terminalWaiters.append($0) }
        }

        private func signalTerminal() {
            let all = terminalWaiters
            terminalWaiters = []
            all.forEach { $0.resume() }
        }
    }

    private func session(_ writer: GatedWriter) -> NavigationSessionManager {
        let route = NavigableRoute(name: "Free Walk", waypoints: [], lapCount: 1, isLoop: false, totalDistance: 0)
        let mgr = NavigationSessionManager(route: route)
        mgr.writesSnapshots = false
        mgr.makeWorkoutWriter = { _ in writer }
        return mgr
    }

    @Test("A walk saved while Health is still starting is finished once the start has run, with the time it ended",
          .timeLimit(.minutes(5)))
    func saveBeforeStartReturns() async {
        let writer = GatedWriter()
        let mgr = session(writer)
        mgr.totalDistanceCovered = 820
        let start = Task { @MainActor in await mgr.startWorkout(at: Date()) }
        await writer.startHeld()

        let endedAt = Date(timeIntervalSince1970: 1_000)
        let finish = Task { @MainActor in await mgr.finishWorkoutSession(endedAt: endedAt) }

        writer.releaseStart()
        await start.value
        await finish.value

        #expect(writer.finishes.count == 1)
        #expect(writer.finishes.first?.distance == 820)
        #expect(writer.finishes.first?.end == endedAt, "Health gets the end the caller took, not the time cleanup ran")
        #expect(!writer.finishedBeforeStart)
        #expect(writer.discards == 0)
        #expect(mgr.workoutWriter == nil)
    }

    @Test("A walk discarded while Health is still starting discards the workout once it has begun",
          .timeLimit(.minutes(5)))
    func discardBeforeStartReturns() async {
        let writer = GatedWriter()
        let mgr = session(writer)
        let start = Task { @MainActor in await mgr.startWorkout(at: Date()) }
        await writer.startHeld()

        mgr.discardWorkoutSession()
        #expect(writer.discards == 0, "not discarded before it has begun")

        writer.releaseStart()
        await start.value
        await writer.terminalCalled()

        #expect(writer.discards == 1)
        #expect(writer.finishes.isEmpty)
        #expect(!writer.finishedBeforeStart)
        #expect(mgr.workoutWriter == nil)
    }

    @Test("Ending after the start has returned still finishes at once and only once", .timeLimit(.minutes(5)))
    func saveAfterStart() async {
        let writer = GatedWriter()
        let mgr = session(writer)
        let start = Task { @MainActor in await mgr.startWorkout(at: Date()) }
        await writer.startHeld()
        writer.releaseStart()
        await start.value

        await mgr.finishWorkoutSession()
        await mgr.finishWorkoutSession()
        #expect(writer.finishes.count == 1)
        #expect(writer.discards == 0)
    }
}
