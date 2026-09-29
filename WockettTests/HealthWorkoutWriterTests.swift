import Testing
import Foundation
import HealthKit
@testable import PoCSquat

/// Starting a walk must not wait on the Health daemon on the main thread.
struct HealthWorkoutWriterTests {

    @Test("The Health permission check runs off the main thread, even when a walk starts from the main actor")
    @MainActor
    func permissionCheckIsOffMain() async {
        let ranOnMain = Flag()
        _ = await HealthWorkoutWriter.canWriteWorkouts {
            ranOnMain.set(Thread.isMainThread)
            return .notDetermined
        }
        #expect(ranOnMain.value == false)
    }

    @Test("Only sharing permission counts as permission to save a workout")
    func onlySharingAuthorizedCounts() async {
        #expect(await HealthWorkoutWriter.canWriteWorkouts { .sharingAuthorized })
        #expect(await HealthWorkoutWriter.canWriteWorkouts { .sharingDenied } == false)
        #expect(await HealthWorkoutWriter.canWriteWorkouts { .notDetermined } == false)
    }
}

/// A Bool the check can set from whatever thread it runs on.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? { lock.withLock { stored } }
    func set(_ newValue: Bool) { lock.withLock { stored = newValue } }
}
