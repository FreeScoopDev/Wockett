import MessageUI
import SwiftUI

// MARK: - Pause Resume Control

struct PauseResumeControl: View {
    let sessionLabel: String
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(wkt: .pauseCircle)
                .wktIcon(.inline, tint: .earthOrange, filled: true)
            Text("\(sessionLabel) Paused")
                .font(.wktHeading(12))
                .foregroundColor(.earthOrange)
            Spacer()
            Button {
                onResume()
            } label: {
                Label {
                    Text("Resume")
                } icon: {
                    Image(wkt: .play)
                        .wktIcon(.inline, tint: .white, onFill: true)
                }
                .font(.wktHeading(12))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.earthGreenFill.opacity(0.9))
                .foregroundColor(.white).cornerRadius(8)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.earthOrange.opacity(0.1))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Break Prompt Alert

struct BreakPromptAlert: ViewModifier {
    @Binding var isPresented: Bool
    let activityMode: ActivityMode
    let onEnd: () -> Void
    let onKeepTracking: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Still \(activityMode.gerund.capitalized)?", isPresented: $isPresented) {
                Button("End \(activityMode.sessionLabel)") { onEnd() }
                Button("Keep Tracking", role: .cancel) { onKeepTracking() }
            } message: {
                Text("You haven't moved in a few minutes. End the \(activityMode.noun) or keep tracking?")
            }
    }
}

// MARK: - Driving Suspected Banner

struct DrivingSuspectedBanner: View {
    let activityMode: ActivityMode
    let onStillWalking: () -> Void
    let onEndWalk: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(wkt: .vehicle)
                .wktIcon(.row, tint: .red.opacity(0.85))
            VStack(alignment: .leading, spacing: 2) {
                Text("This looks faster than a \(activityMode.noun)")
                    .font(.caption.bold()).foregroundColor(.earthCream)
                Text("Still \(activityMode.gerund), or are you driving?")
                    .font(.caption2).foregroundColor(.earthMuted)
            }
            Spacer()
            Button { onStillWalking() } label: {
                Text("Still \(activityMode.gerund)")
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.earthGreenFill.opacity(0.85))
                    .foregroundColor(.white).cornerRadius(8)
            }
            .accessibilityHint("Dismisses the alert and continues your session")
            Button { onEndWalk() } label: {
                Text("End \(activityMode.noun)")
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.red.opacity(0.75))
                    .foregroundColor(.white).cornerRadius(8)
            }
            .accessibilityHint("Stops and saves this session")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.red.opacity(0.1))
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
