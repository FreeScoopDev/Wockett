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
