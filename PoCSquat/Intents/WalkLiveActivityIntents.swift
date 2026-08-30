import AppIntents
import ActivityKit

// MARK: - End Walk Live Activity Intent
//
// This file is compiled into both PoCSquat (main app) and WocketWidgetExtension.
// WOCKET_WIDGET is set in the widget extension's Swift Active Compilation Conditions.

struct EndWalkLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "End Walk"
    static var description = IntentDescription("Saves and ends the active Wockett walk from the Live Activity.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WOCKET_WIDGET
        ActiveWalkStore.shared.saveAndEndActiveSession()
        // If the session was already gone (orphaned Live Activity from a prior process),
        // reap it via the system list so it disappears cleanly.
        if ActiveWalkStore.shared.session == nil {
            await WalkLiveActivityManager.shared.endAllActivities()
        }
        #endif
        return .result()
    }
}

// MARK: - Toggle Pause Live Activity Intent

struct ToggleWalkPauseLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or Resume Walk"
    static var description = IntentDescription("Pauses or resumes the active Wockett walk from the Live Activity.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WOCKET_WIDGET
        guard let session = ActiveWalkStore.shared.session else { return .result() }
        if session.isPaused { session.resume() } else { session.pause() }

        // Push the Live Activity update directly — don't rely on WalkNavigationView's
        // onChange, which only fires while SwiftUI is actively rendering. With
        // openAppWhenRun = false the app never comes to the foreground, so that
        // handler may not run for a while (or until the user opens the app).
        let dist = session.totalDistanceCovered
        let elapsed = session.elapsedTime
        let paused = session.isPaused
        let pace = dist > 100 && elapsed > 10 ? elapsed / (dist / 1000) : nil
        await WalkLiveActivityManager.shared.update(
            distanceCovered: dist,
            elapsedSeconds: Int(elapsed),
            isPaused: paused,
            paceSecsPerKm: pace,
            pausedDuration: session.totalPausedDuration,
            pauseTime: paused ? Date() : nil
        )
        #endif
        return .result()
    }
}
