import AppIntents
import SwiftUI

// MARK: - Start Walk Intent
//
// "Hey Siri, start a walk with Wockett"
// "Hey Siri, start a 30-minute walk"
// Also surfaces in the Shortcuts app for automation.

struct StartWalkIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a Walk"
    static var description = IntentDescription("Opens Wockett and starts a free walk session.")

    static var openAppWhenRun: Bool = true

    @Parameter(title: "Duration", description: "Optional walk duration in minutes.")
    var durationMinutes: Int?

    @Parameter(title: "Mode", description: "Walking, cycling, or indoor.")
    var mode: WalkModeAppEnum?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a \(\.$durationMinutes) minute \(\.$mode) session")
    }

    func perform() async throws -> some IntentResult {
        // Deep-link into a free walk via the notification approach.
        // The app reads this on foreground and opens the correct walk mode.
        let ud = UserDefaults.standard
        ud.set(durationMinutes, forKey: "intent_durationMinutes")
        ud.set(mode?.rawValue ?? "walking", forKey: "intent_activityMode")
        ud.set(true, forKey: "intent_startWalkPending")
        return .result()
    }
}

// MARK: - Log Today's Steps Intent

struct GetStepsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Today's Steps"
    static var description = IntentDescription("Returns today's step count from Wockett.")

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let steps = UserDefaults.standard.integer(forKey: "bg_todaySteps")
        return .result(value: steps)
    }
}

// MARK: - WalkModeAppEnum

enum WalkModeAppEnum: String, AppEnum {
    case walking, cycling, indoor

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Walk Mode")
    static var caseDisplayRepresentations: [WalkModeAppEnum: DisplayRepresentation] = [
        .walking: .init(title: "Walking"),
        .cycling: .init(title: "Cycling"),
        .indoor:  .init(title: "Indoor")
    ]
}

// MARK: - App Shortcuts Provider
//
// Registers the canonical Siri phrase for each intent so users don't need
// to set them up in the Shortcuts app manually.

struct WockettShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartWalkIntent(),
            phrases: [
                "Start a walk with \(.applicationName)",
                "Start \(.applicationName)",
                "Begin a walk in \(.applicationName)"
            ],
            shortTitle: "Start a Walk",
            systemImageName: "figure.walk"
        )
        AppShortcut(
            intent: GetStepsIntent(),
            phrases: [
                "How many steps today in \(.applicationName)",
                "Check my steps in \(.applicationName)"
            ],
            shortTitle: "Today's Steps",
            systemImageName: "figure.walk.motion"
        )
    }
}
