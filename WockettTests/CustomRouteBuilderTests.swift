import Testing
import CoreLocation
import MapKit
@testable import PoCSquat

/// The route builder works out directions with `await`, and the map and the
/// Undo button stayed live meanwhile. Undo during the calculation removed
/// points the loop was about to index, a fatal "Index out of range"
/// (2026-10-26 review, finding 5).
@MainActor
struct CustomRouteBuilderTests {

    /// Holds each directions answer until the test releases it. The test
    /// waits on a continuation, never on polling: on the CI runner every turn
    /// of a `Task.yield()` loop goes to the back of the main actor's queue.
    private final class GatedDirections {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var heldWaiters: [CheckedContinuation<Void, Never>] = []
        private(set) var asked = 0

        func lookup() async -> MKRoute? {
            asked += 1
            await withCheckedContinuation { c in
                waiting.append(c)
                let arrived = heldWaiters
                heldWaiters = []
                arrived.forEach { $0.resume() }
            }
            return nil
        }

        /// Returns once a lookup is waiting for `release()`.
        func held() async {
            if !waiting.isEmpty { return }
            await withCheckedContinuation { heldWaiters.append($0) }
        }

        func release() {
            let all = waiting
            waiting = []
            all.forEach { $0.resume() }
        }
    }

    private func point(_ n: Int) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 35.78 + Double(n) * 1e-3, longitude: -78.64)
    }

    private func builder(_ gate: GatedDirections, points: Int) -> CustomRouteBuilder {
        CustomRouteBuilder(initialWaypoints: (0..<points).map(point)) { _, _, _ in await gate.lookup() }
    }

    @Test("Undo while the first leg is being worked out changes nothing and does not trap",
          .timeLimit(.minutes(5)))
    func undoDuringRecompute() async {
        let gate = GatedDirections()
        let b = builder(gate, points: 3)
        let compute = Task { @MainActor in await b.computeAllLegs() }
        await gate.held()

        #expect(b.isComputing)
        b.undoLast()
        b.undoLast()
        #expect(b.waypoints.count == 3)

        gate.release()
        await gate.held()      // the second leg
        gate.release()
        await compute.value
        #expect(b.waypoints.count == 3)
        #expect(!b.isComputing)
    }

    @Test("A tap while directions are being worked out adds no point", .timeLimit(.minutes(5)))
    func tapDuringRecompute() async {
        let gate = GatedDirections()
        let b = builder(gate, points: 2)
        let compute = Task { @MainActor in await b.computeAllLegs() }
        await gate.held()

        b.addWaypoint(point(9))
        #expect(b.waypoints.count == 2)

        gate.release()
        await compute.value
        #expect(gate.asked == 1)
    }

    @Test("Closing the loop is not offered twice, and Undo waits for it", .timeLimit(.minutes(5)))
    func loopToggleDuringLoopLeg() async {
        let gate = GatedDirections()
        let b = builder(gate, points: 3)
        b.toggleLoop()
        await gate.held()

        #expect(b.isComputing)
        b.toggleLoop()
        b.undoLast()
        #expect(b.waypoints.count == 3)
        // The unguarded toggle starts its work in a Task, which has not run
        // yet at this point; give it the turns it needs before counting.
        for _ in 0..<5 { await Task.yield() }
        #expect(gate.asked == 1)

        gate.release()
    }

    @Test("A new point is a busy builder from the tap, before its task first runs", .timeLimit(.minutes(5)))
    func busyFromTheTap() async {
        let gate = GatedDirections()
        let b = builder(gate, points: 1)
        b.addWaypoint(point(1))
        #expect(b.isComputing)
        b.undoLast()
        #expect(b.waypoints.count == 2)
        await gate.held()
        gate.release()
    }

    @Test("Edits work again once the calculation is done", .timeLimit(.minutes(5)))
    func editsResume() async {
        let gate = GatedDirections()
        let b = builder(gate, points: 3)
        let compute = Task { @MainActor in await b.computeAllLegs() }
        await gate.held()
        gate.release()
        await gate.held()
        gate.release()
        await compute.value

        b.undoLast()
        #expect(b.waypoints.count == 2)
    }

    @Test("The calculation works from its own copy of the points", .timeLimit(.minutes(5)))
    func copyOfWaypoints() async {
        let gate = GatedDirections()
        let b = builder(gate, points: 3)
        let compute = Task { @MainActor in await b.computeAllLegs() }
        await gate.held()

        // `waypoints` is public, so something other than the guarded edits can
        // still shorten it; the loop must not index the live array.
        b.waypoints.removeLast()
        b.waypoints.removeLast()
        gate.release()
        await gate.held()
        gate.release()
        await compute.value
    }
}
