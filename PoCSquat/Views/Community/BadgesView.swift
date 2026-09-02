import SwiftUI
import UIKit

// MARK: - Badges Content View (push-safe — no NavigationStack, no Done button)

struct BadgesContentView: View {
    @EnvironmentObject private var stepManager:  StepManager
    @EnvironmentObject private var historyStore: WalkHistoryStore
    @AppStorage("pinnedBadgeIds_v1") private var pinnedBadgeIdsStr: String = ""

    var streakStore: StreakStore = .shared

    private var sessions:      [WalkSession] { historyStore.sessions }
    private var todaySteps:    Int           { stepManager.todaySteps }
    private var dailyGoal:     Int           { stepManager.currentGoal }

    private var cleanSessions: [WalkSession] { sessions.filter { !$0.flaggedPossibleVehicle } }
    private var totalKm:       Double { streakStore.totalKm(from: cleanSessions) }
    private var currentStreak: Int    { streakStore.currentStreak }
    private var appleADayStreak: Int  { streakStore.appleADayStreak }
    private var longestStreak: Int    { streakStore.longestStreak }

    private var pinnedIds: [String] {
        pinnedBadgeIdsStr.isEmpty ? [] : pinnedBadgeIdsStr.split(separator: ",").map(String.init)
    }

    private var distanceBadges:    [WalkBadge] { walkBadges.filter { if case .distance = $0.type { true } else { false } } }
    private var streakBadges:      [WalkBadge] { walkBadges.filter { if case .streak   = $0.type { true } else { false } } }
    private var timeBadges:        [WalkBadge] { walkBadges.filter {
        switch $0.type { case .earlyBird, .nightOwl: true; default: false }
    }}
    private var metaBadges:        [WalkBadge] { walkBadges.filter {
        if case .badgeCount = $0.type { true } else { false }
    }}
    private var rideBadges:        [WalkBadge] { walkBadges.filter {
        switch $0.type { case .rideKm, .rideStreak, .crossTrainDay: true; default: false }
    }}
    private var petBadges:         [WalkBadge] { walkBadges.filter {
        switch $0.type { case .petWalks, .multiPetWalk: true; default: false }
    }}
    private var explorerBadges:    [WalkBadge] { walkBadges.filter {
        switch $0.type { case .communityRoutesCompleted, .routesBookmarked, .customRouteCreated, .customRouteShared: true; default: false }
    }}
    private var consistencyBadges: [WalkBadge] { walkBadges.filter {
        switch $0.type { case .indoorWalks: true; default: false }
    }}
    private var collectionBadges:  [WalkBadge] { walkBadges.filter {
        switch $0.type { case .walkNotesAdded, .manualEntries, .wockettsGiven, .wockettsReceived: true; default: false }
    }}
    private var socialBadges:      [WalkBadge] { walkBadges.filter {
        switch $0.type { case .challengeShared: true; default: false }
    }}

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    pinHint
                    streakSection
                    personalRecordsSection
                    badgeSection(title: "Distance",    badges: distanceBadges)
                    badgeSection(title: "Streaks",     badges: streakBadges)
                    badgeSection(title: "Time-Based",  badges: timeBadges)
                    badgeSection(title: "Rides",       badges: rideBadges)
                    badgeSection(title: "Pets",        badges: petBadges)
                    badgeSection(title: "Explorer",    badges: explorerBadges)
                    badgeSection(title: "Consistency", badges: consistencyBadges)
                    badgeSection(title: "Collection",  badges: collectionBadges)
                    badgeSection(title: "Social",      badges: socialBadges)
                    badgeSection(title: "Meta",        badges: metaBadges)
                    if currentStreak > 0 { shareButton }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Streaks & Badges")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            streakStore.refresh(sessions: sessions, todaySteps: todaySteps, dailyGoal: dailyGoal)
            Task {
                let count = await CommunityRouteService.shared.fetchReceivedWocketts()
                UserDefaults.standard.set(count, forKey: "wkt_wocketts_received")
            }
        }
    }

    // MARK: - Pin hint

    private var pinHint: some View {
        HStack(spacing: 8) {
            Image(wkt: .pin)
                .wktIcon(.inline, tint: .earthOrange, filled: true)
            Text("Pin up to 2 badges to your home screen")
                .font(.wktBody(12))
                .foregroundColor(.earthMuted)
            Spacer()
            Text("\(pinnedIds.count)/2")
                .wktTechnical(11)
                .foregroundColor(pinnedIds.count == 2 ? .earthOrange : .earthMuted)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.earthCard)
        .cornerRadius(12)
    }

    // MARK: - Streak tiles

    private var streakSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                streakTile(value: currentStreak,   label: "Goal Streak",  emoji: "🔥")
                streakTile(value: appleADayStreak, label: "Apple a Day",  emoji: "🍎")
                streakTile(value: longestStreak,   label: "Best Streak",  emoji: "🏆")
            }
            HStack(spacing: 8) {
                Image(wkt: .walk).wktIcon(.inline, tint: .earthGreen)
                    .accessibilityHidden(true)
                Text(String(format: "%.1f km walked all time", totalKm))
                    .font(.wktBody(14)).foregroundColor(.earthCream)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12).padding(.horizontal, 16)
            .background(Color.earthCard).cornerRadius(12)
        }
    }

    private func streakTile(value: Int, label: String, emoji: String) -> some View {
        VStack(spacing: 4) {
            Text(emoji).font(.system(size: 24))
            Text("\(value)")
                .font(.wktDisplay(26))
                .foregroundColor(.earthCream)
            Text("day\(value == 1 ? "" : "s")")
                .wktTechnical(9).foregroundColor(.earthMuted)
            Text(label)
                .wktTechnical(9)
                .foregroundColor(.earthMuted)
                .textCase(.uppercase)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.earthCard)
        .cornerRadius(14)
    }

    // MARK: - Personal Records

    @ViewBuilder
    private var personalRecordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Personal Records")
                .font(.wktHeading(17)).foregroundColor(.earthCream)
            if sessions.isEmpty {
                Text("Complete walks to unlock personal records.")
                    .font(.wktBody(12)).foregroundColor(.earthMuted)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.earthCard).cornerRadius(12)
            } else {
                VStack(spacing: 8) {
                    ForEach(computedPersonalRecords, id: \.label) { rec in
                        HStack(spacing: 12) {
                            Text(rec.emoji)
                                .font(.system(size: 20))
                                .frame(width: 32, alignment: .center)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rec.label)
                                    .wktTechnical(10)
                                    .foregroundColor(.earthMuted)
                                    .textCase(.uppercase)
                                Text(rec.value)
                                    .font(.wktHeading(15))
                                    .foregroundColor(.earthCream)
                            }
                            Spacer()
                            if let detail = rec.detail {
                                Text(detail)
                                    .wktTechnical(10)
                                    .foregroundColor(.earthMuted.opacity(0.7))
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(Color.earthCard)
                        .cornerRadius(12)
                    }
                }
            }
        }
    }

    private var computedPersonalRecords: [PersonalRecord] {
        var records: [PersonalRecord] = []
        let cal = Calendar.current
        let shortDate: (Date) -> String = {
            let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
            return df.string(from: $0)
        }

        var stepsByDay: [Date: Int] = [:]
        for s in cleanSessions {
            let day = cal.startOfDay(for: s.date)
            stepsByDay[day, default: 0] += s.estimatedSteps
        }
        if let best = stepsByDay.max(by: { $0.value < $1.value }) {
            records.append(PersonalRecord(
                emoji: "🏆", label: "Best Day",
                value: best.value.formatted() + " steps", detail: shortDate(best.key)
            ))
        }

        if let longest = cleanSessions.max(by: { $0.totalDistance < $1.totalDistance }) {
            records.append(PersonalRecord(
                emoji: "📏", label: "Longest Walk",
                value: longest.distanceText, detail: shortDate(longest.date)
            ))
        }

        let walkSessions = cleanSessions.filter {
            $0.totalDistance >= 500 && $0.elapsedTime > 60 && $0.activityType != "cycling"
        }
        if let fastest = walkSessions.min(by: {
            let p1 = ($0.elapsedTime / 60) / ($0.totalDistance / 1000)
            let p2 = ($1.elapsedTime / 60) / ($1.totalDistance / 1000)
            return p1 < p2
        }) {
            let useMetric = Locale.current.measurementSystem != .us
            let divisor   = useMetric ? 1000.0 : 1609.34
            let unit      = useMetric ? "/km"   : "/mi"
            let mpu       = (fastest.elapsedTime / 60) / (fastest.totalDistance / divisor)
            let mins      = Int(mpu)
            let secs      = Int((mpu - Double(mins)) * 60)
            records.append(PersonalRecord(
                emoji: "⚡️", label: "Best Pace",
                value: String(format: "%d:%02d%@", mins, secs, unit), detail: shortDate(fastest.date)
            ))
        }

        return records
    }

    // MARK: - Badge section

    private func badgeSection(title: String, badges: [WalkBadge]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.wktHeading(17)).foregroundColor(.earthCream)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(badges) { badge in
                    badgeTile(badge)
                }
            }
        }
    }

    private func badgeTile(_ badge: WalkBadge) -> some View {
        let earned   = badge.isEarned(sessions: cleanSessions, currentStreak: currentStreak)
        let progress = badge.progress(sessions: cleanSessions, currentStreak: currentStreak)
        let isPinned = pinnedIds.contains(badge.id)
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.earthMuted.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(earned ? Color.earthGreen : Color.accentNotice,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(badge.emoji)
                    .font(.system(size: 26))
                    .opacity(earned ? 1.0 : 0.25)
                    .grayscale(earned ? 0 : 1)
            }
            .frame(width: 44, height: 44)
            Text(badge.name)
                .font(.wktHeading(12))
                .foregroundColor(earned ? .earthCream : .earthMuted)
            Text(badge.description)
                .font(.wktBody(9))
                .foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 14).padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(Color.earthCard.opacity(earned ? 1 : 0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isPinned ? Color.earthOrange.opacity(0.6) : (earned ? Color.earthGreen.opacity(0.45) : Color.clear), lineWidth: 1.5)
        )
        .overlay(alignment: .topTrailing) {
            Button {
                togglePin(badge.id)
            } label: {
                Image(wkt: .pin)
                    .wktIcon(.inline, tint: isPinned ? .earthOrange : .earthMuted.opacity(0.4), filled: isPinned)
                    .padding(7)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pin badge")
            .accessibilityValue(isPinned ? "Pinned" : "Unpinned")
            .accessibilityAddTraits(isPinned ? .isSelected : [])
        }
    }

    private func togglePin(_ id: String) {
        var ids = pinnedIds
        if ids.contains(id) {
            ids.removeAll { $0 == id }
        } else if ids.count < 2 {
            ids.append(id)
        } else {
            ids.removeFirst()
            ids.append(id)
        }
        pinnedBadgeIdsStr = ids.joined(separator: ",")
    }

    // MARK: - Share challenge

    private var shareButton: some View {
        let challenge = Int(Double(dailyGoal) * 1.1)
        let text = "I've walked \(currentStreak) day\(currentStreak == 1 ? "" : "s") in a row on Wockett 🔥 Think you can hit \(challenge.formatted()) steps today?"
        return Button {
            UserDefaults.standard.set(true, forKey: "wkt_challengeShared")
            let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.windows.first?.rootViewController?
                .present(av, animated: true)
        } label: {
            Label {
                Text("Challenge a Friend")
            } icon: {
                Image(wkt: .share).wktIcon(.row, tint: .white, onFill: true)
            }
            .font(.wktHeading(17))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.earthGreenFill)
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Badges View (sheet wrapper — keeps existing callers compiling)

struct BadgesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BadgesContentView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.foregroundColor(.earthGreen)
                    }
                }
        }
    }
}

// MARK: - Personal Record model

private struct PersonalRecord {
    let emoji:  String
    let label:  String
    let value:  String
    let detail: String?
}

// MARK: - Preview

#Preview("Badges") {
    NavigationStack {
        BadgesContentView()
    }
    .environmentObject(StepManager())
    .environmentObject(WalkHistoryStore())
}
