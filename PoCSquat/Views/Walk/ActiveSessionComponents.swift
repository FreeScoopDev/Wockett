import MessageUI
import SwiftUI

// MARK: - Pause Resume Control

/// The paused banner, at the normal text sizes. At the accessibility sizes
/// the panel header says "Paused" instead (`ActiveSessionView.pausedLine`).
struct PauseResumeControl: View {
    let sessionLabel: String
    let onResume: () -> Void

    var body: some View {
        WktBanner(symbol: .pauseCircle, tint: .earthOrange, title: "\(sessionLabel) paused") {
            WktPillButton(title: "Resume", action: onResume)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.paused")
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Break Prompt Alert

struct BreakPromptAlert: ViewModifier {
    @Binding var isPresented: Bool
    let wording: SessionWording
    let onEnd: () -> Void
    let onKeepTracking: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Still \(wording.gerund.capitalized)?", isPresented: $isPresented) {
                Button("End \(wording.sessionLabel)") { onEnd() }
                Button("Keep Tracking", role: .cancel) { onKeepTracking() }
            } message: {
                Text("You haven't moved in a few minutes. End the \(wording.noun) or keep tracking?")
            }
    }
}

// MARK: - Driving Suspected Banner

struct DrivingSuspectedBanner: View {
    let wording: SessionWording
    let onStillWalking: () -> Void
    let onEndWalk: () -> Void

    var body: some View {
        WktBanner(symbol: .vehicle, tint: .red,
                  title: "This looks faster than a \(wording.noun)",
                  detail: "Still \(wording.gerund), or are you driving?") {
            WktPillButton(title: "Still \(wording.gerund)", action: onStillWalking)
                .accessibilityHint("Dismisses the alert and continues your session")
            WktPillButton(title: "End \(wording.noun)", tint: .red, action: onEndWalk)
                .accessibilityHint("Stops and saves this session")
        }
    }
}

// MARK: - Message Compose Sheet

struct MessageComposeSheet: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = recipients
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            controller.dismiss(animated: true)
        }
    }
}
