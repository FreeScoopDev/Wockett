import AppIntents
import ActivityKit

// MARK: - End Walk Live Activity Intent
//
// This file is compiled into both PoCSquat (main app) and WocketWidgetExtension.
// WOCKET_WIDGET is set in the widget extension's Swift Active Compilation Conditions,
// so the perform() bodies — which reference main-app-only ActiveWalkStore — are only
// compiled in the main app. iOS routes Live Activity button taps to the main app
// process at runtime, so the widget extension never needs to execute perform().

struct EndWalkLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "End Walk"
    static var description = IntentDescription("Saves and ends the active Wockett walk from the Live Activity.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WOCKET_WIDGET
        ActiveWalkStore.shared.saveAndEndActiveSession()
        #endif
        return .result()
    }
}

// MARK: - Toggle Pause Live Activity Intent

struct ToggleWalkPauseLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or Resume Walk"
    static var description = IntentDescription("Pauses or resumes the active Wockett walk from the Live Activity.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WOCKET_WIDGET
        guard let session = ActiveWalkStore.shared.session else { return .result() }
        if session.isPaused { session.resume() } else { session.pause() }
        #endif
        return .result()
    }
}
