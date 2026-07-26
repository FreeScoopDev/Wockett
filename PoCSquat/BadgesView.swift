import SwiftUI

// MARK: - Badges & Streaks View

struct BadgesView: View {
    let sessions: [WalkSession]
    let todaySteps: Int
    let dailyGoal: Int
    @Environment(\.dismiss) private var dismiss

    var streakStore: StreakStore = .shared

    private var totalKm: Double { streakStore.totalKm(from: sessions) }
    private var currentStreak: Int { streakStore.currentStreak }
    private var appleADayStreak: Int { streakStore.appleADayStreak }
    private var longestStreak: Int { streakStore.longestStreak }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        streakSection
                        badgesSection
                        if currentStreak > 0 { shareButton }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Streaks & Badges")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.earthGreen)
                }
            }
        }
        .onAppear {
            streakStore.refresh(sessions: sessions, todaySteps: todaySteps, dailyGoal: dailyGoal)
        }
    }

    // MARK: - Streak tiles

    private var streakSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                streakTile(value: currentStreak,    label: "Goal Streak",   emoji: "🔥")
                streakTile(value: appleADayStreak,  label: "Apple a Day",   emoji: "🍎")
                streakTile(value: longestStreak,    label: "Best Streak",   emoji: "🏆")
            }

            HStack(spacing: 8) {
                Image(systemName: "figure.walk").foregroundColor(.earthGreen)
                Text(String(format: "%.1f km walked all time", totalKm))
                    .font(.subheadline).foregroundColor(.earthCream)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12).padding(.horizontal, 16)
            .background(Color.earthCard).cornerRadius(12)
        }
    }

    private func streakTile(value: Int, label: String, emoji: String) -> some View {
        VStack(spacing: 4) {
            Text(emoji).font(.system(size: 28))
            Text("\(value)")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundColor(.earthCream)
            Text("day\(value == 1 ? "" : "s")")
                .font(.caption2).foregroundColor(.earthMuted)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.earthCard)
        .cornerRadius(14)
    }

    // MARK: - Badges grid

    private var badgesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Distance Badges")
                .font(.headline).foregroundColor(.earthCream)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(walkBadges) { badge in
                    badgeTile(badge)
                }
            }
        }
    }

    private func badgeTile(_ badge: WalkBadge) -> some View {
        let earned = totalKm >= badge.requiredKm
        return VStack(spacing: 6) {
            Text(badge.emoji)
                .font(.system(size: 30))
                .opacity(earned ? 1.0 : 0.2)
                .grayscale(earned ? 0 : 1)
            Text(badge.name)
                .font(.caption.bold())
                .foregroundColor(earned ? .earthCream : .earthMuted)
            Text(badge.description)
                .font(.system(size: 9))
                .foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 14).padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(Color.earthCard.opacity(earned ? 1 : 0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(earned ? Color.earthGreen.opacity(0.45) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: - Share challenge

    private var shareButton: some View {
        let challenge = Int(Double(dailyGoal) * 1.1)
        let text = "I've walked \(currentStreak) day\(currentStreak == 1 ? "" : "s") in a row on Wockett 🔥 Think you can hit \(challenge.formatted()) steps today?"
        return ShareLink(item: text) {
            Label("Challenge a Friend", systemImage: "square.and.arrow.up")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.earthGreen)
                .foregroundColor(.white)
                .cornerRadius(14)
        }
    }
}
