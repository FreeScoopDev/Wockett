import SwiftUI

// MARK: - App Theme

// MARK: - App Theme  (light/dark adaptive)

extension Color {
    /// Primary background — warm parchment in light, iOS standard dark in dark
    static let earthBg = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1) // #1C1C1E
            : UIColor(red: 0.961, green: 0.957, blue: 0.949, alpha: 1) // #F5F4F2
    })
    /// Card / row surfaces — white in light, elevated dark in dark
    static let earthCard = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.173, green: 0.173, blue: 0.180, alpha: 1) // #2C2C2E
            : UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1) // #FFFFFF
    })
    /// Primary accent green — deep forest in light, vibrant in dark
    static let earthGreen = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.373, green: 0.659, blue: 0.322, alpha: 1) // #5FA852
            : UIColor(red: 0.180, green: 0.471, blue: 0.200, alpha: 1) // #2E7833
    })
    /// Secondary accent — warm burnt orange in light, brighter in dark
    static let earthOrange = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.878, green: 0.522, blue: 0.243, alpha: 1) // #E0853E
            : UIColor(red: 0.769, green: 0.400, blue: 0.114, alpha: 1) // #C4661D
    })
    /// Primary text — near-black in light, warm cream from icon in dark
    static let earthCream = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.949, green: 0.922, blue: 0.847, alpha: 1) // #F2EBD8
            : UIColor(red: 0.102, green: 0.118, blue: 0.094, alpha: 1) // #1A1E18
    })
    /// Secondary text — warm grey in both modes
    static let earthMuted = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.620, green: 0.608, blue: 0.580, alpha: 1) // #9E9B94
            : UIColor(red: 0.431, green: 0.447, blue: 0.420, alpha: 1) // #6E726B
    })
}

/// Adaptive UIColor versions for use in UIKit map renderers and annotations
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

struct ContentView: View {
    private let workouts: [WorkoutConfig] = [.squats, .pushups]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()

                VStack(spacing: 32) {
                    // Header
                    VStack(spacing: 6) {
                        Text("Wockett")
                            .font(.system(size: 36, weight: .black, design: .rounded))
                            .foregroundColor(.earthCream)
                        Text("Walk more. Move better.")
                            .font(.subheadline)
                            .foregroundColor(.earthMuted)
                    }
                    .padding(.top, 60)

                    // Workout cards
                    VStack(spacing: 16) {
                        ForEach(workouts) { config in
                            NavigationLink(destination: WorkoutSessionView(config: config)) {
                                WorkoutCard(config: config)
                            }
                            .buttonStyle(.plain)
                        }

                        NavigationLink(destination: StepCounterView()) {
                            StepsCard()
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal)

                    Spacer()

                    Text("Requires iPhone XS or later • Rear camera")
                        .font(.caption2)
                        .foregroundColor(Color.earthMuted.opacity(0.5))
                        .padding(.bottom, 24)
                }
            }
            .navigationBarHidden(true)
        }
    }
}

// MARK: - Steps Card

struct StepsCard: View {
    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.earthGreen.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "figure.walk")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.earthGreen)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Step Counter")
                    .font(.title3.bold())
                    .foregroundColor(.earthCream)
                Text("Daily steps · goals · route suggestions")
                    .font(.subheadline)
                    .foregroundColor(.earthMuted)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.earthMuted)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.earthCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.earthGreen.opacity(0.35), lineWidth: 1)
                )
        )
    }
}

// MARK: - Workout Selection Card

struct WorkoutCard: View {
    let config: WorkoutConfig

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(config.color.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: config.icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(config.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(config.name)
                    .font(.title3.bold())
                    .foregroundColor(.earthCream)
                Text(config.description)
                    .font(.subheadline)
                    .foregroundColor(.earthMuted)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.earthMuted)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.earthCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(config.color.opacity(0.35), lineWidth: 1)
                )
        )
    }
}
