import AppIntents
import ActivityKit

// MARK: - End Walk Live Activity Intent
//
// Tapping "End Walk" on the lock-screen Live Activity or Dynamic Island
// calls this intent in the main app process (not the extension process),
// so it can reach ActiveWalkStore.shared directly. The widget extension
// sees a matching stub declaration in WocketWidgetLiveActivity.swift that
// carries the same struct name so AppIntents routes the perform() here.

struct EndWalkLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "End Walk"
    static var description = IntentDescription("Saves and ends the active Wockett walk from the Live Activity.")

    @MainActor
    func perform() async throws -> some IntentResult {
        ActiveWalkStore.shared.saveAndEndActiveSession()
        return .result()
    }
}

// MARK: - Toggle Pause Live Activity Intent

struct ToggleWalkPauseLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or Resume Walk"
    static var description = IntentDescription("Pauses or resumes the active Wockett walk from the Live Activity.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let session = ActiveWalkStore.shared.session else { return .result() }
        if session.isPaused { session.resume() } else { session.pause() }
        return .result()
    }
}
