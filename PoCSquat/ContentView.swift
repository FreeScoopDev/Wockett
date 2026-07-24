import SwiftUI

struct ContentView: View {
    private let workouts: [WorkoutConfig] = [.squats, .pushups]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 32) {
                    // Header
                    VStack(spacing: 6) {
                        Text("Wockett")
                            .font(.system(size: 36, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                        Text("Walk more. Move better.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.5))
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
                        .foregroundColor(.white.opacity(0.25))
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
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "figure.walk")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.green)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Step Counter")
                    .font(.title3.bold())
                    .foregroundColor(.white)
                Text("Daily steps · goals · route suggestions")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.green.opacity(0.25), lineWidth: 1)
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
                    .foregroundColor(.white)
                Text(config.description)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(config.color.opacity(0.25), lineWidth: 1)
                )
        )
    }
}
