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
        print("🔵 [LiveActivityIntent] EndWalk perform() ENTERED — pid \(ProcessInfo.processInfo.processIdentifier), bundle \(Bundle.main.bundleIdentifier ?? "?")")
        #if !WOCKET_WIDGET
        print("🔵 [LiveActivityIntent] EndWalk — WOCKET_WIDGET not defined, this is the app-target compilation")
        if let _ = ActiveWalkStore.shared.session {
            print("🔵 [LiveActivityIntent] EndWalk — session found, isActive=\(ActiveWalkStore.shared.isActive), calling saveAndEndActiveSession()")
        } else {
            print("🔴 [LiveActivityIntent] EndWalk — ActiveWalkStore.shared.session is NIL in this process")
        }
        ActiveWalkStore.shared.saveAndEndActiveSession()
        print("🔵 [LiveActivityIntent] EndWalk — saveAndEndActiveSession() returned, isActive now=\(ActiveWalkStore.shared.isActive)")
        #else
        print("🔴 [LiveActivityIntent] EndWalk — WOCKET_WIDGET IS defined, this is the WIDGET EXTENSION compilation — logic body skipped by design")
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
        print("🟢 [LiveActivityIntent] TogglePause perform() ENTERED — pid \(ProcessInfo.processInfo.processIdentifier), bundle \(Bundle.main.bundleIdentifier ?? "?")")
        #if !WOCKET_WIDGET
        guard let session = ActiveWalkStore.shared.session else {
            print("🔴 [LiveActivityIntent] TogglePause — ActiveWalkStore.shared.session is NIL in this process")
            return .result()
        }
        print("🟢 [LiveActivityIntent] TogglePause — session found, isPaused before=\(session.isPaused)")
        if session.isPaused { session.resume() } else { session.pause() }
        print("🟢 [LiveActivityIntent] TogglePause — isPaused after=\(session.isPaused)")
        #else
        print("🔴 [LiveActivityIntent] TogglePause — WOCKET_WIDGET IS defined, this is the WIDGET EXTENSION compilation — logic body skipped by design")
        #endif
        return .result()
    }
}
