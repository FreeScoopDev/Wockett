import MapKit
import SwiftUI
import UIKit

// MARK: - Session panel components
//
// Pieces of the active-session screen as redesigned on 2026-09-24 (Joe chose
// option B of the "Active Walk Screen" canvas): a glance panel that pulls up
// for everything else, a Finish that needs a one-second hold and then a
// confirmation, and a heading beam on the user's dot with a north-up /
// heading-up switch. Guided and free sessions share all of it.

// MARK: - The user's dot, with a heading beam

/// The blue dot, with a beam pointing where the person faces. `angle` is in
/// degrees clockwise from the top of the screen (heading minus the map's own
/// rotation); nil draws the dot alone.
struct UserHeadingDot: View {
    let angle: Double?

    static let size: CGFloat = 96

    var body: some View {
        ZStack {
            if let angle {
                BeamShape()
                    .fill(RadialGradient(colors: [Color.userDot.opacity(0.45), Color.userDot.opacity(0)],
                                         center: .center, startRadius: 6, endRadius: Self.size / 2))
                    .rotationEffect(.degrees(angle))
                    .animation(.easeOut(duration: 0.25), value: angle)
            }
            Circle()
                .fill(Color.userDot)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(Color.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }
}

/// A 60° wedge from the centre, pointing up.
private struct BeamShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: centre)
        path.addArc(center: centre, radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(-120), endAngle: .degrees(-60), clockwise: false)
        path.closeSubpath()
        return path
    }
}

extension Color {
    /// The system's location blue, so the dot reads as "you" the way it does in Maps.
    static let userDot = Color(UIColor.systemBlue)
}

/// The same dot for the UIKit map guided sessions use. MapKit gives no beam
/// outside follow-with-heading, so this view replaces its user-location view.
@Observable
final class HeadingBeamState {
    var angle: Double?
}

final class UserHeadingAnnotationView: MKAnnotationView {
    static let reuseID = "userHeading"
    let beam = HeadingBeamState()
    private var host: UIHostingController<HostedDot>?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        // The view's own frame is just the dot and the beam draws outside it:
        // a 96 pt frame hid the route's checkpoint pins when zoomed out.
        let dot: CGFloat = 24
        frame = CGRect(x: 0, y: 0, width: dot, height: dot)
        clipsToBounds = false
        let controller = UIHostingController(rootView: HostedDot(beam: beam))
        controller.view.backgroundColor = .clear
        let overhang = (UserHeadingDot.size - dot) / 2
        controller.view.frame = CGRect(x: -overhang, y: -overhang,
                                       width: UserHeadingDot.size, height: UserHeadingDot.size)
        controller.view.isUserInteractionEnabled = false
        addSubview(controller.view)
        host = controller
        canShowCallout = false
        displayPriority = .required
        // Out of collision entirely: at a trailhead the dot sits on the
        // route's Start pin, and with collision on MapKit hid the pin.
        collisionMode = .none
        zPriority = .max
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    struct HostedDot: View {
        let beam: HeadingBeamState
        var body: some View { UserHeadingDot(angle: beam.angle) }
    }
}

// MARK: - Map orientation controls

/// Recentre, and switch between north up (with the beam) and heading up
/// (the map turns with the person). Two-finger rotation also works; the
/// map's compass appears when it is rotated and taps back to north.
struct MapOrientationControls: View {
    @Binding var headingUp: Bool
    let onRecenter: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onRecenter) {
                Image(wkt: .locationOn)
                    .wktIcon(.row, tint: .userDot, filled: true)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .accessibilityLabel("Center the map on me")
            .accessibilityIdentifier("session.recenter")

            Button {
                headingUp.toggle()
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                HStack(spacing: 6) {
                    Image(wkt: headingUp ? .headingUp : .northUp)
                        .wktIcon(.inline, tint: headingUp ? .white : .earthCream)
                    Text(headingUp ? "Heading up" : "North up")
                        .font(.caption.bold())
                        .foregroundColor(headingUp ? .white : .earthCream)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background {
                    if headingUp { Color.earthGreenFill } else { Rectangle().fill(.ultraThinMaterial) }
                }
                .clipShape(Capsule())
            }
            .accessibilityLabel("Map orientation")
            .accessibilityValue(headingUp ? "Heading up" : "North up")
            .accessibilityHint("Switches between north up and turning the map with you")
            .accessibilityIdentifier("session.orientation")
        }
    }
}

// MARK: - Hold to finish

/// Finish needs a one-second press, with a fill that tracks the hold and a
/// firm tap when it completes. A short tap only shows how to use it: an
/// accidental brush of the screen must never end a session (Joe, 2026-09-24).
/// VoiceOver's activate goes straight to the confirmation, which still guards it.
struct HoldToFinishButton: View {
    let activityMode: ActivityMode
    let onComplete: () -> Void

    static let holdSeconds = 1.0

    @State private var progress: CGFloat = 0
    @State private var isPressing = false
    @State private var completed = false
    @State private var showHint = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color.earthCard)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.red.opacity(0.18))
                    .frame(width: geo.size.width * progress)
            }
            RoundedRectangle(cornerRadius: 14).stroke(Color.red.opacity(0.85), lineWidth: 1.5)
            VStack(spacing: 1) {
                Text(isPressing ? "Keep holding" : "Hold to finish")
                    .font(.subheadline.bold())
                    .foregroundColor(.red)
                Text(showHint ? "Press and hold for 1 second" : "1 second")
                    .font(.caption2)
                    .foregroundColor(.earthMuted)
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 56)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onLongPressGesture(minimumDuration: Self.holdSeconds, maximumDistance: 40) {
            completed = true
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            isPressing = false
            progress = 0
            onComplete()
        } onPressingChanged: { pressing in
            if pressing {
                completed = false
                isPressing = true
                showHint = false
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.linear(duration: Self.holdSeconds)) { progress = 1 }
            } else {
                isPressing = false
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
                // Released early: explain, briefly. The completion callback
                // may arrive just after this one, hence the short wait.
                Task {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !completed else { return }
                    showHint = true
                    try? await Task.sleep(for: .seconds(2.5))
                    showHint = false
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Finish \(activityMode.noun)")
        .accessibilityHint("Press and hold for one second, then confirm")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onComplete() }
    }
}

// MARK: - Stats

struct SessionStatTile: View {
    let value: String
    let label: String
    var prominent = false

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.wktDisplay(prominent ? 28 : 19))
                .monospacedDigit()
                .foregroundColor(.earthCream)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .wktTechnical(9)
                .textCase(.uppercase)
                .foregroundColor(.earthMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, prominent ? 2 : 8)
        .background(prominent ? Color.clear : Color.earthCard)
        .cornerRadius(12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// How far along a guided route the session is.
struct SessionProgressBar: View {
    let covered: Double
    let total: Double
    let coveredText: String
    let totalText: String

    private var fraction: Double { total > 0 ? min(1, max(0, covered / total)) : 0 }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.earthMuted.opacity(0.2))
                    Capsule().fill(Color.earthGreenFill).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)
            HStack {
                Text(coveredText)
                Spacer()
                Text(totalText)
            }
            .font(.caption2)
            .foregroundColor(.earthMuted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(coveredText) of \(totalText)")
    }
}

// MARK: - Controls

/// A session setting with what it does written out, instead of a bare icon.
struct SessionToggleRow: View {
    let icon: WktSymbol
    let tint: Color
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                Image(wkt: icon)
                    .wktIcon(.row, tint: isOn ? tint : .earthMuted, filled: isOn)
                    .frame(width: 36, height: 36)
                    .background(Color.earthCard)
                    .cornerRadius(10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.bold()).foregroundColor(.earthCream)
                    Text(detail).font(.caption).foregroundColor(.earthMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(.earthGreenFill)
        .padding(.vertical, 4)
    }
}

// MARK: - Finish confirmation

/// The second step after the hold: keep going is the default action, so the
/// least destructive choice is the easiest to hit.
struct FinishConfirmationView: View {
    let activityMode: ActivityMode
    let summary: String
    let onKeepGoing: () -> Void
    let onFinish: () -> Void
    /// Guided routes can be saved to My Routes on the way out; nil hides it.
    let onFinishAndSaveRoute: (() -> Void)?
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Finish your \(activityMode.noun)?")
                    .font(.title2.bold())
                    .foregroundColor(.earthCream)
                Text(summary)
                    .font(.subheadline)
                    .foregroundColor(.earthMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 6)

            Button(action: onKeepGoing) {
                Text("Keep \(activityMode.gerund)")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.earthGreenFill)
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .accessibilityIdentifier("session.keepGoing")

            Button(action: onFinish) {
                Text("Finish and save")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.red)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.red.opacity(0.85), lineWidth: 1.5))
            }
            .accessibilityIdentifier("session.confirmFinish")

            if let onFinishAndSaveRoute {
                Button(action: onFinishAndSaveRoute) {
                    Text("Finish and save the route to My Routes")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundColor(.earthGreen)
                }
            }

            Button(role: .destructive, action: onDiscard) {
                Text("Discard this \(activityMode.noun)")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .accessibilityIdentifier("session.discard")
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 12)
        .presentationDetents([.height(onFinishAndSaveRoute == nil ? 340 : 390)])
        .presentationDragIndicator(.visible)
    }
}
