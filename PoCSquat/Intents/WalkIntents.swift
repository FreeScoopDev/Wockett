import AppIntents
import SwiftUI

// MARK: - Start Walk Intent
//
// "Hey Siri, start a walk with Wockett"
// Also surfaces in the Shortcuts app for automation.
//
// The intent runs in the app process (openAppWhenRun brings the app to the
// front) and posts to WalkIntentInbox; SquatCounterApp consumes it and Home
// opens the walk screen. Until 1.14 it set a flag that nothing read, so
// Siri only opened the app.

struct StartWalkIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a Walk"
    static var description = IntentDescription("Opens Wockett and starts a free walk session.")

    static var openAppWhenRun: Bool = true

    @Parameter(title: "Mode", description: "Walking, running, cycling, or indoor.")
    var mode: WalkModeAppEnum?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a \(\.$mode) session")
    }

    func perform() async throws -> some IntentResult {
        let mode = WalkIntentInbox.mode(fromIntentValue: self.mode?.rawValue)
        await WalkIntentInbox.shared.post(WalkIntentRequest(mode: mode))
        return .result()
    }
}

// MARK: - Today's Steps Intent

struct GetStepsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Today's Steps"
    static var description = IntentDescription("Returns today's step count from Wockett.")

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let dayStart = StepManager.trackingDayStart()
        let steps = await SiriStepsAnswer.fromHealth(dayStart: dayStart)
            ?? SiriStepsAnswer.cached(in: UserDefaults(suiteName: SiriStepsAnswer.appGroup))
        guard let steps else {
            return .result(value: 0, dialog: "Wockett can't read your steps right now. Open the app to refresh them.")
        }
        return .result(value: steps, dialog: "You've taken \(steps.formatted()) steps today.")
    }
}

// MARK: - WalkModeAppEnum

enum WalkModeAppEnum: String, AppEnum {
    case walking, running, cycling, indoor

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Walk Mode")
    static var caseDisplayRepresentations: [WalkModeAppEnum: DisplayRepresentation] = [
        .walking: .init(title: "Walking"),
        .running: .init(title: "Running"),
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
