import SwiftUI

// MARK: - App Theme (light/dark adaptive)

extension Color {
    static let earthBg = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1)
            : UIColor(red: 0.961, green: 0.957, blue: 0.949, alpha: 1)
    })
    static let earthCard = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.173, green: 0.173, blue: 0.180, alpha: 1)
            : UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1)
    })
    static let earthGreen = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.373, green: 0.659, blue: 0.322, alpha: 1)
            : UIColor(red: 0.180, green: 0.471, blue: 0.200, alpha: 1)
    })
    static let earthOrange = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.878, green: 0.522, blue: 0.243, alpha: 1)
            : UIColor(red: 0.769, green: 0.400, blue: 0.114, alpha: 1)
    })
    static let earthCream = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.949, green: 0.922, blue: 0.847, alpha: 1)
            : UIColor(red: 0.102, green: 0.118, blue: 0.094, alpha: 1)
    })
    static let earthMuted = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.620, green: 0.608, blue: 0.580, alpha: 1)
            : UIColor(red: 0.431, green: 0.447, blue: 0.420, alpha: 1)
    })

    // MARK: Design system foundation (added for v1.10 unified design system)
    static let earthLine = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.149, green: 0.188, blue: 0.165, alpha: 1)   // #26302A
            : UIColor(red: 0.894, green: 0.878, blue: 0.835, alpha: 1)   // #E4E0D5
    })
    static let accentRun = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.910, green: 0.545, blue: 0.322, alpha: 1)   // #E88B52
            : UIColor(red: 0.769, green: 0.333, blue: 0.102, alpha: 1)   // #C4551A
    })
    static let accentRide = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.310, green: 0.702, blue: 0.741, alpha: 1)   // #4FB3BD
            : UIColor(red: 0.082, green: 0.478, blue: 0.522, alpha: 1)   // #157A85
    })
    static let accentIndoor = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.608, green: 0.549, blue: 0.878, alpha: 1)   // #9B8CE0
            : UIColor(red: 0.357, green: 0.294, blue: 0.690, alpha: 1)   // #5B4BB0
    })

}

// MARK: - Typography system (v1.10 unified design system)
//
// Three tiers, two font families, zero new dependencies:
//   Display    — SF Pro Rounded Black.    Hero numbers, wordmark, big stats.
//   UI         — SF Pro Rounded Heavy/Semibold. Headings, labels, buttons.
//   Technical  — SF Mono Semibold, tracked +14%. All-caps eyebrow labels,
//                stat captions, and other "readout" text (GPS READY, PACE,
//                ELAPSED, badge percentages, etc).
//
// The splash screen already commits to Rounded Black; this makes the rest
// of the app follow through on that instead of using ad hoc system fonts.

extension Font {
    /// Display tier — SF Pro Rounded Black. Use for hero numbers and the wordmark.
    static func wktDisplay(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black, design: .rounded)
    }

    /// UI tier, heading weight — SF Pro Rounded Heavy. Section titles, card headers.
    static func wktHeading(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .rounded)
    }

    /// UI tier, body weight — SF Pro Rounded Semibold. Buttons, list labels, body text.
    static func wktBody(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
}

/// Technical tier — SF Mono Semibold, tracked +14%. Apply via the `.wktTechnical()`
/// view modifier below rather than `.font()` directly, since tracking is a
/// separate Text/View modifier in SwiftUI, not part of `Font` itself.
private struct WktTechnicalText: ViewModifier {
    var size: CGFloat
    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .tracking(size * 0.14)
    }
}

extension View {
    /// Technical tier — SF Mono Semibold, tracked +14%. Default size 11pt
    /// matches the small all-caps eyebrow labels and stat captions in the
    /// design mockups (GPS READY, PACE, ELAPSED, badge percentages, etc).
    func wktTechnical(_ size: CGFloat = 11) -> some View {
        modifier(WktTechnicalText(size: size))
    }
}


extension UIColor {
    static let brandGreen = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.373, green: 0.659, blue: 0.322, alpha: 1)
            : UIColor(red: 0.180, green: 0.471, blue: 0.200, alpha: 1)
    }
    static let brandOrange = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.878, green: 0.522, blue: 0.243, alpha: 1)
            : UIColor(red: 0.769, green: 0.400, blue: 0.114, alpha: 1)
    }
}

// MARK: - Shared Button Styles

struct BounceButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// Triangle clipped to the bottom-right corner — used for the activity mode fold on action tiles.
struct CornerFoldShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.height))
        p.addLine(to: CGPoint(x: rect.width, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        p.closeSubpath()
        return p
    }
}
