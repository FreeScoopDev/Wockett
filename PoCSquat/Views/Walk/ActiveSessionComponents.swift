import MessageUI
import SwiftUI

// MARK: - Session Stat Cell

struct SessionStatCell: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.caption).foregroundColor(.earthGreen)
            Text(value).font(.subheadline.bold()).foregroundColor(.earthCream)
            Text(label).font(.caption2).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Session Stats Bar

struct SessionStatsBar: View {
    let session: NavigationSessionManager
    let activityIcon: String
    let showsRemaining: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showsRemaining {
                    SessionStatCell(value: session.distanceText(session.distanceToNextWaypoint), label: "to next", icon: "location.fill")
                    Rectangle().frame(width: 0.5, height: 36).foregroundColor(Color.earthMuted.opacity(0.25))
                    SessionStatCell(value: session.distanceText(session.remainingDistance), label: "remaining", icon: "flag.fill")
                    Rectangle().frame(width: 0.5, height: 36).foregroundColor(Color.earthMuted.opacity(0.25))
                }
                SessionStatCell(value: session.elapsedText, label: "elapsed", icon: "clock.fill")
                Rectangle().frame(width: 0.5, height: 36).foregroundColor(Color.earthMuted.opacity(0.25))
                SessionStatCell(value: session.paceText, label: session.paceLabel, icon: "speedometer")
            }
            .padding(.vertical, 14)

            if session.estimatedSteps > 0 {
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color.earthMuted.opacity(0.25))
                HStack(spacing: 0) {
                    VStack(spacing: 5) {
                        Image(systemName: activityIcon).font(.caption).foregroundColor(.earthGreen)
                        Text(session.estimatedSteps.formatted()).font(.subheadline.bold()).foregroundColor(.earthCream)
                        Text("steps").font(.caption2).foregroundColor(.earthMuted)
                        if let cad = session.cadence, cad > 0 {
                            Text("\(Int(cad))/min")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.earthGreen)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    if let eta = session.estimatedSecondsRemaining {
                        Rectangle().frame(width: 0.5, height: 36).foregroundColor(Color.earthMuted.opacity(0.25))
                        SessionStatCell(value: fmtDuration(eta), label: "est. left", icon: "timer")
                    }
                }
                .padding(.vertical, 14)
            }
        }
    }
}

private func fmtDuration(_ t: TimeInterval) -> String {
    let s = Int(t); let m = s / 60
    return m < 60 ? "\(m)m \(s % 60)s" : "\(m / 60)h \(m % 60)m"
}

// MARK: - Pause Resume Control

struct PauseResumeControl: View {
    let sessionLabel: String
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .foregroundColor(.earthOrange)
            Text("\(sessionLabel) Paused")
                .font(.caption.bold())
                .foregroundColor(.earthOrange)
            Spacer()
            Button {
                onResume()
            } label: {
                Label("Resume", systemImage: "play.fill")
                    .font(.caption.bold())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.earthGreen.opacity(0.9))
                    .foregroundColor(.white).cornerRadius(8)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.earthOrange.opacity(0.1))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Session End Dialog

struct SessionEndDialog: ViewModifier {
    @Binding var isPresented: Bool
    let activityMode: ActivityMode
    let onSaveAndEnd: () -> Void
    let onEnd: () -> Void
    let onDiscard: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("End \(activityMode.sessionLabel)?", isPresented: $isPresented) {
                Button("Save Route & End \(activityMode.sessionLabel)") { onSaveAndEnd() }
                Button("End \(activityMode.sessionLabel)") { onEnd() }
                Button("Discard \(activityMode.sessionLabel)", role: .destructive) { onDiscard() }
                Button("Keep \(activityMode.gerund.capitalized)", role: .cancel) {}
            } message: {
                Text("Save this \(activityMode.noun) to your history? You can also save the route to My Routes so you can \(activityMode.noun) it again.")
            }
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
            Image(systemName: "car.fill")
                .font(.title3).foregroundColor(.red.opacity(0.85))
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
                    .background(Color.earthGreen.opacity(0.85))
                    .foregroundColor(.white).cornerRadius(8)
            }
            Button { onEndWalk() } label: {
                Text("End \(activityMode.noun)")
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.red.opacity(0.75))
                    .foregroundColor(.white).cornerRadius(8)
            }
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
