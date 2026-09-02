import AppIntents
import SwiftUI
import WidgetKit

// Widget-local symbol names (WktSymbol is in the app target, unavailable here)
private let wktWalkIconName = "figure.walk"

// MARK: - Start Walk Control
//
// Appears in Control Center (iOS 18+). Tapping opens Wockett and
// signals the app to begin a free walk session.

struct WocketStartWalkControl: ControlWidget {
    static let kind = "com.scoops.wockett.StartWalkControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenWockettForWalkIntent()) {
                Label("Start Walk", systemImage: wktWalkIconName)
            }
        }
        .displayName("Start Walk")
        .description("Open Wockett and begin a free walk.")
    }
}

private struct OpenWockettForWalkIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Wockett for Walk"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Write to shared App Group so the main app can read it on next foreground
        let ud = UserDefaults(suiteName: "group.com.scoops.wockett")
        ud?.set(true, forKey: "intent_startWalkPending")
        ud?.set("walking", forKey: "intent_activityMode")
        return .result()
    }
}
