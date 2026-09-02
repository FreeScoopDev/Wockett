//
//  DesignSystem.swift
//  PoCSquat
//
//  Created by Joe Amanatidis on 8/31/26.
//

// Shared design tokens (colors + typography) for the v1.10 unified design
// system. Lives in both the PoCSquat app target and WocketWidgetExtension so
// the widget/Live Activity can reference the exact same tokens instead of a
// separately maintained copy that can drift out of sync.

import SwiftUI
import UIKit

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
    // These 6 colors serve two different visual roles: TEXT/ICON color (labels,
    // SF Symbol tints, map polylines, progress-ring strokes -- the color IS
    // the visible content), and solid BUTTON-FILL background with white
    // text/icons on top (nearly every primary CTA in the app). A v1.10
    // accessibility audit found a single value can't serve both roles well in
    // dark mode: bright enough to read as text on the dark background (5.8-
    // 6.9:1) leaves white-on-fill at only 2.5-2.9:1, below WCAG's 3:1 floor.
    // An earlier fix darkened these tokens directly to fix the fill case,
    // which then broke the text case (dropped below the 4.5:1 normal-text
    // bar). The complete fix: these stay their original bright values (best
    // as text/icons), and each has a matching "Fill" token below (e.g.
    // earthGreenFill) tuned separately for the white-on-fill role. Use the
    // Fill variant for any solid/near-solid `.background()`, `.tint()` on a
    // filled control, or MapKit `markerTintColor` with a white glyph on top;
    // use the plain token for everything else.
    static let earthGreen = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.373, green: 0.659, blue: 0.322, alpha: 1)
            : UIColor(red: 0.180, green: 0.471, blue: 0.200, alpha: 1)
    })
    static let earthGreenFill = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.291, green: 0.514, blue: 0.251, alpha: 1)   // white-fill 4.55:1
            : UIColor(red: 0.180, green: 0.471, blue: 0.200, alpha: 1)   // light already clears 4.5:1 as-is
    })
    static let earthOrange = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.878, green: 0.522, blue: 0.243, alpha: 1)
            : UIColor(red: 0.769, green: 0.400, blue: 0.114, alpha: 1)
    })
    static let earthOrangeFill = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.667, green: 0.397, blue: 0.185, alpha: 1)   // white-fill 4.54:1
            : UIColor(red: 0.700, green: 0.364, blue: 0.104, alpha: 1)   // light original was 3.99:1, nudged darker for 4.69:1
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
    static let accentRunFill = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.655, green: 0.392, blue: 0.232, alpha: 1)   // white-fill 4.63:1
            : UIColor(red: 0.754, green: 0.326, blue: 0.100, alpha: 1)   // light original was a razor-thin 4.51:1, nudged to 4.66:1
    })
    static let accentRide = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.310, green: 0.702, blue: 0.741, alpha: 1)   // #4FB3BD
            : UIColor(red: 0.082, green: 0.478, blue: 0.522, alpha: 1)   // #157A85
    })
    static let accentRideFill = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.220, green: 0.498, blue: 0.526, alpha: 1)   // white-fill 4.61:1
            : UIColor(red: 0.082, green: 0.478, blue: 0.522, alpha: 1)   // light already clears 4.5:1 as-is
    })
    static let accentIndoor = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.608, green: 0.549, blue: 0.878, alpha: 1)   // #9B8CE0
            : UIColor(red: 0.357, green: 0.294, blue: 0.690, alpha: 1)   // #5B4BB0
    })
    static let accentIndoorFill = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.474, green: 0.428, blue: 0.685, alpha: 1)   // white-fill 4.54:1
            : UIColor(red: 0.357, green: 0.294, blue: 0.690, alpha: 1)   // light already clears 4.5:1 as-is
    })

    // Recurring "utility" colors found duplicated as flat literals across the codebase
    // during the v1.10 consistency pass (routes/info blue, notice/attention amber,
    // health-metric blue-purple) — consolidated here so every call site shares one
    // adaptive definition instead of copy-pasted, non-adaptive RGB values.
    static let accentInfo = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.45, green: 0.62, blue: 0.92, alpha: 1)
            : UIColor(red: 0.28, green: 0.49, blue: 0.84, alpha: 1)
    })
    static let accentInfoFill = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.333, green: 0.459, blue: 0.681, alpha: 1)   // white-fill 4.63:1
            : UIColor(red: 0.258, green: 0.451, blue: 0.773, alpha: 1)   // light original was 4.06:1, nudged darker for 4.68:1
    })
    static let accentNotice = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.95, green: 0.82, blue: 0.25, alpha: 1)
            // Light-mode value darkened for the v1.10 accessibility audit --
            // the original (0.82, 0.70, 0.05) measured 1.89:1 against earthBg
            // (WCAG requires 3:1 even for large text/UI, 4.5:1 for normal
            // text), essentially illegible on the cream background. This
            // darker gold hits 4.75:1 / 5.22:1 against earthBg/earthCard.
            : UIColor(red: 0.55, green: 0.40, blue: 0.02, alpha: 1)
    })
    static let accentHealth = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.58, green: 0.66, blue: 0.95, alpha: 1)
            : UIColor(red: 0.42, green: 0.52, blue: 0.88, alpha: 1)
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
        let s = UIFontMetrics(forTextStyle: .body).scaledValue(for: size)
        return .system(size: s, weight: .black, design: .rounded)
    }

    /// UI tier, heading weight — SF Pro Rounded Heavy. Section titles, card headers.
    static func wktHeading(_ size: CGFloat) -> Font {
        let s = UIFontMetrics(forTextStyle: .body).scaledValue(for: size)
        return .system(size: s, weight: .heavy, design: .rounded)
    }

    /// UI tier, body weight — SF Pro Rounded Semibold. Buttons, list labels, body text.
    static func wktBody(_ size: CGFloat) -> Font {
        let s = UIFontMetrics(forTextStyle: .body).scaledValue(for: size)
        return .system(size: s, weight: .semibold, design: .rounded)
    }
}

/// Technical tier — SF Mono Semibold, tracked +14%. Apply via the `.wktTechnical()`
/// view modifier below rather than `.font()` directly, since tracking is a
/// separate Text/View modifier in SwiftUI, not part of `Font` itself.
private struct WktTechnicalText: ViewModifier {
    var size: CGFloat
    func body(content: Content) -> some View {
        let s = UIFontMetrics(forTextStyle: .body).scaledValue(for: size)
        return content
            .font(.system(size: s, weight: .semibold, design: .monospaced))
            .tracking(s * 0.14)
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
    // Same TEXT/ICON-vs-FILL split as the Color tokens above: MapKit renderers
    // (MKPolylineRenderer.strokeColor, a line -- text-like role) and
    // MKMarkerAnnotationView.markerTintColor (a filled pin with a white glyph
    // on top -- fill role) both take UIColor, and need different values for
    // the same reason the SwiftUI buttons do.
    static let brandGreen = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.373, green: 0.659, blue: 0.322, alpha: 1)
            : UIColor(red: 0.180, green: 0.471, blue: 0.200, alpha: 1)
    }
    static let brandGreenFill = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.291, green: 0.514, blue: 0.251, alpha: 1)
            : UIColor(red: 0.180, green: 0.471, blue: 0.200, alpha: 1)
    }
    static let brandOrange = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.878, green: 0.522, blue: 0.243, alpha: 1)
            : UIColor(red: 0.769, green: 0.400, blue: 0.114, alpha: 1)
    }
    static let brandOrangeFill = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.667, green: 0.397, blue: 0.185, alpha: 1)
            : UIColor(red: 0.769, green: 0.400, blue: 0.114, alpha: 1)
    }

    // UIKit mirrors of the SwiftUI accentRun/Ride/Indoor tokens above --
    // MapKit renderers (MKPolylineRenderer, MKMarkerAnnotationView) take
    // UIColor, not Color, so this is how NavigationSession's guided-route
    // map can share the same per-activity accent palette used everywhere
    // else (Dashboard tiles, free-walk map polyline).
    static let accentRun = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.910, green: 0.545, blue: 0.322, alpha: 1)
            : UIColor(red: 0.769, green: 0.333, blue: 0.102, alpha: 1)
    }
    static let accentRunFill = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.655, green: 0.392, blue: 0.232, alpha: 1)
            : UIColor(red: 0.754, green: 0.326, blue: 0.100, alpha: 1)
    }
    static let accentRide = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.310, green: 0.702, blue: 0.741, alpha: 1)
            : UIColor(red: 0.082, green: 0.478, blue: 0.522, alpha: 1)
    }
    static let accentRideFill = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.220, green: 0.498, blue: 0.526, alpha: 1)
            : UIColor(red: 0.082, green: 0.478, blue: 0.522, alpha: 1)
    }
    static let accentIndoor = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.608, green: 0.549, blue: 0.878, alpha: 1)
            : UIColor(red: 0.357, green: 0.294, blue: 0.690, alpha: 1)
    }
    static let accentIndoorFill = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.474, green: 0.428, blue: 0.685, alpha: 1)
            : UIColor(red: 0.357, green: 0.294, blue: 0.690, alpha: 1)
    }
}

