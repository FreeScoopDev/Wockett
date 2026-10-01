import SwiftUI

// MARK: - Activity picker
//
// Four segments that choose an activity; the Start button under them starts
// it (2026-09-30 redesign). The old tiles started a session on tap, which
// made "which activity" and "go" one gesture, so a stray tap began a walk.
// The selected segment takes the action green whatever the activity, so the
// screen has one "this is chosen" colour; the activity colour is the icon's.

struct HomeActivityPicker: View {
    @Binding var selection: ActivityMode

    static let modes: [ActivityMode] = [.walking, .running, .cycling, .stationary]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.modes, id: \.rawValue) { mode in
                segment(mode)
            }
        }
    }

    private func segment(_ mode: ActivityMode) -> some View {
        let isSelected = selection == mode
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = mode }
        } label: {
            VStack(spacing: 6) {
                Image(wkt: mode.wktSymbol)
                    .wktIcon(.row, tint: isSelected ? .white : mode.tileColor, onFill: isSelected)
                Text(mode.sessionLabel)
                    .font(.wktLabel)
                    .foregroundColor(isSelected ? .white : .earthCream)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 68)
            .wktCardBackground(fill: isSelected ? .earthGreenFill : .earthCard)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.96))
        .accessibilityLabel(mode.sessionLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(Self.identifier(for: mode))
    }

    static func identifier(for mode: ActivityMode) -> String {
        switch mode {
        case .walking:    return "home.tile.walk"
        case .running:    return "home.tile.run"
        case .cycling:    return "home.tile.ride"
        case .stationary: return "home.tile.indoor"
        }
    }
}
