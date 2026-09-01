import SwiftUI
import CloudKit

// MARK: - Challenges Content View (push-safe — no NavigationStack, no Done button)

struct ChallengesContentView: View {
    @EnvironmentObject private var stepManager:  StepManager
    @EnvironmentObject private var historyStore: WalkHistoryStore

    @State private var challenges:        [WalkChallenge] = []
    @State private var isLoading         = false
    @State private var loadError:        String?          = nil
    @State private var selectedChallenge: WalkChallenge?  = nil
    @State private var showCreate        = false

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            if isLoading && challenges.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().tint(.earthGreen)
                    Text("Loading challenges…")
                        .font(.subheadline).foregroundColor(.earthMuted)
                }
            } else if let err = loadError, challenges.isEmpty {
                errorView(err)
            } else {
                challengeList
            }
        }
        .navigationTitle("Challenges")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCreate = true } label: {
                    Image(systemName: "plus").foregroundColor(.earthGreen)
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showCreate, onDismiss: { Task { await load() } }) {
            CreateChallengeView()
        }
        .sheet(item: $selectedChallenge) { challenge in
            ChallengeDetailView(challenge: challenge)
        }
    }

    // MARK: - Helpers (ChallengesContentView)

    private var challengeList: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerBanner.padding(.bottom, 16)
                if challenges.isEmpty && !isLoading {
                    emptyState
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(challenges) { challenge in
                            ChallengeCard(
                                challenge: challenge,
                                isJoined: ChallengeService.shared.hasJoined(challenge),
                                onHide: { challenges.removeAll { $0.id == challenge.id } }
                            )
                            .onTapGesture { selectedChallenge = challenge }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                if let err = loadError {
                    Text(err)
                        .font(.caption).foregroundColor(.earthOrange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24).padding(.top, 8)
                }
            }
            .padding(.bottom, 40)
        }
    }

    private var headerBanner: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.earthGreen.opacity(0.12))
                        .frame(width: 52, height: 52)
                    Text("🏆").font(.system(size: 26))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Community Challenges")
                        .font(.headline).foregroundColor(.earthCream)
                    Text("Walk together, compete together")
                        .font(.caption).foregroundColor(.earthMuted)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Text("🏁").font(.system(size: 48))
            Text("No active challenges yet")
                .font(.headline).foregroundColor(.earthCream)
            Text("Tap + to create the first community challenge and invite others to join.")
                .font(.subheadline).foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 40)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.icloud")
                .font(.system(size: 40)).foregroundColor(.earthMuted)
            Text(message)
                .font(.subheadline).foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button { Task { await load() } } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.subheadline.bold())
                    .foregroundColor(.earthGreen)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Color.earthCard)
                    .cornerRadius(10)
            }
        }
    }

    private func load() async {
        isLoading = true; loadError = nil
        do {
            challenges = try await ChallengeService.shared.fetchActiveChallenges()
        } catch let ck as CKError {
            #if DEBUG
            print("[ChallengeService] CKError \(ck.code.rawValue): \(ck)")
            #endif
            loadError = ckErrorMessage(ck)
        } catch {
            #if DEBUG
            print("[ChallengeService] Error: \(error)")
            #endif
            loadError = "Couldn't load challenges: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func ckErrorMessage(_ error: CKError) -> String {
        switch error.code {
        case .notAuthenticated:
            return "Sign into iCloud (Settings → [Your Name]) to view challenges."
        case .networkUnavailable, .networkFailure:
            return "No internet connection. Check your connection and retry."
        case .invalidArguments:
            return "Missing queryable index on CloudKit schema. In CloudKit Console, add a Queryable index on 'endDate' (Challenge) and 'challengeRecordName' (ChallengeEntry), then redeploy to Production."
        case .unknownItem:
            return "Challenge record type not found. Ensure the Challenge schema is deployed to Production in CloudKit Console."
        default:
            return "iCloud error (\(error.code.rawValue)): \(error.localizedDescription)"
        }
    }
}

// MARK: - Challenges View (sheet wrapper — keeps existing callers compiling)

struct ChallengesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChallengesContentView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }.foregroundColor(.earthGreen)
                    }
                }
        }
    }
}

// MARK: - Challenge Card

private struct ChallengeCard: View {
    let challenge: WalkChallenge
    let isJoined:  Bool
    var onHide: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.earthGreen.opacity(0.1))
                    .frame(width: 50, height: 50)
                Text(challenge.emoji).font(.system(size: 26))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(challenge.title)
                        .font(.subheadline.bold())
                        .foregroundColor(.earthCream)
                        .lineLimit(1)
                    if isJoined {
                        Text("Joined")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.earthGreen)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.earthGreen.opacity(0.15))
                            .cornerRadius(5)
                    }
                }
                HStack(spacing: 8) {
                    Text(challenge.goalText)
                        .font(.caption).foregroundColor(.earthMuted)
                    Text("·").font(.caption).foregroundColor(.earthMuted.opacity(0.4))
                    Text(challenge.timeRemainingText)
                        .font(.caption)
                        .foregroundColor(challenge.daysRemaining(from: Date()) <= 1 ? .earthOrange : .earthMuted)
                }
                Text("by \(challenge.authorName)")
                    .font(.system(size: 10)).foregroundColor(.earthMuted.opacity(0.55))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundColor(.earthMuted.opacity(0.4))
        }
        .padding(14)
        .background(Color.earthCard)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isJoined ? Color.earthGreen.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contextMenu {
            if let onHide {
                Button(role: .destructive) {
                    CommunityModerationStore.shared.report(challenge.id)
                    onHide()
                } label: {
                    Label("Report Challenge", systemImage: "flag")
                }
                Button(role: .destructive) {
                    CommunityModerationStore.shared.block(author: challenge.authorName)
                    onHide()
                } label: {
                    Label("Block \(challenge.authorName)", systemImage: "nosign")
                }
            }
        }
    }
}

// MARK: - Challenge Detail View

struct ChallengeDetailView: View {
    let challenge: WalkChallenge
    @EnvironmentObject private var stepManager:  StepManager
    @EnvironmentObject private var historyStore: WalkHistoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var participants:    [ChallengeParticipant] = []
    @State private var myProgressValue: Int    = 0
    @State private var isLoading              = false
    @State private var isSyncing              = false
    @State private var loadError:       String? = nil
    @State private var syncMessage:     String? = nil

    private var isJoined: Bool { ChallengeService.shared.hasJoined(challenge) }
    private var myRank: Int? {
        guard isJoined else { return nil }
        return participants.firstIndex { $0.isCurrentDevice }.map { $0 + 1 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        heroSection
                        syncSection
                        leaderboardSection
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle(challenge.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.earthGreen)
                }
            }
            .task {
                await loadLeaderboard()
                await loadMyProgress()
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.earthGreen.opacity(0.1))
                        .frame(width: 64, height: 64)
                    Text(challenge.emoji).font(.system(size: 36))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(challenge.goalText)
                        .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundColor(.earthCream)
                    Text(challenge.timeRemainingText)
                        .font(.subheadline)
                        .foregroundColor(challenge.daysRemaining(from: Date()) <= 1 ? .earthOrange : .earthMuted)
                    Text(detailSubtitle)
                        .font(.caption).foregroundColor(.earthMuted.opacity(0.65))
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            if isJoined || myProgressValue > 0 {
                VStack(spacing: 8) {
                    HStack {
                        Text("Your Progress")
                            .font(.caption.bold()).foregroundColor(.earthMuted)
                        Spacer()
                        if let rank = myRank {
                            Text("Rank #\(rank)")
                                .font(.caption.bold()).foregroundColor(.earthGreen)
                        }
                        Text(challenge.progressDisplay(for: myProgressValue))
                            .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundColor(.earthCream)
                    }
                    .padding(.horizontal, 20)

                    GeometryReader { geo in
                        let prog = challenge.progress(for: myProgressValue)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.earthMuted.opacity(0.12))
                            Capsule()
                                .fill(prog >= 1 ? Color.accentNotice : Color.earthGreen)
                                .frame(width: max(6, geo.size.width * prog))
                                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: prog)
                        }
                        .frame(height: 8)
                    }
                    .frame(height: 8)
                    .padding(.horizontal, 20)

                    if challenge.goalType == .pace {
                        Text("Qualifying sessions beat \(challengeFormattedPace(challenge.goalPaceSecsPerKm)) · \(challenge.activityFilterLabel)")
                            .font(.system(size: 10)).foregroundColor(.earthMuted.opacity(0.7))
                            .padding(.horizontal, 20)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var detailSubtitle: String {
        let base = "\(challenge.durationDays)-day challenge"
        let filter = challenge.activityFilter != nil ? " · \(challenge.activityFilterLabel)" : ""
        return "\(base)\(filter) · by \(challenge.authorName)"
    }

    // MARK: - Sync

    private var syncSection: some View {
        VStack(spacing: 10) {
            Button { Task { await syncProgress() } } label: {
                Group {
                    if isSyncing {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white).scaleEffect(0.85)
                            Text("Syncing…")
                        }
                    } else {
                        Label(syncButtonLabel, systemImage: isJoined ? "arrow.triangle.2.circlepath" : "person.badge.plus")
                    }
                }
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.earthGreenFill)
                .foregroundColor(.white)
                .cornerRadius(14)
            }
            .disabled(isSyncing)
            .padding(.horizontal, 20)

            if let msg = syncMessage {
                Text(msg)
                    .font(.caption).foregroundColor(.earthGreen)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: syncMessage)
    }

    private var syncButtonLabel: String {
        switch challenge.goalType {
        case .steps:    return isJoined ? "Sync My Steps"    : "Join & Sync Steps"
        case .distance: return isJoined ? "Sync My Distance" : "Join & Sync Distance"
        case .pace:     return isJoined ? "Sync My Runs"     : "Join & Sync Runs"
        }
    }

    // MARK: - Leaderboard

    @ViewBuilder
    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Leaderboard")
                    .font(.subheadline.bold()).foregroundColor(.earthCream)
                Spacer()
                if isLoading {
                    ProgressView().scaleEffect(0.7).tint(.earthGreen)
                } else {
                    Text("\(participants.count) participant\(participants.count == 1 ? "" : "s")")
                        .font(.caption).foregroundColor(.earthMuted)
                }
            }
            .padding(.horizontal, 20)

            if let err = loadError {
                Text(err)
                    .font(.caption).foregroundColor(.earthOrange)
                    .padding(.horizontal, 20)
            } else if participants.isEmpty && !isLoading {
                Text("Be the first to join this challenge!")
                    .font(.caption).foregroundColor(.earthMuted)
                    .padding(.horizontal, 20)
            } else {
                ForEach(participants.indices, id: \.self) { i in
                    LeaderboardRow(rank: i + 1, participant: participants[i], challenge: challenge)
                        .padding(.horizontal, 20)
                    if i < participants.count - 1 {
                        Divider()
                            .background(Color.earthMuted.opacity(0.1))
                            .padding(.horizontal, 20)
                    }
                }
            }
        }
        .padding(.vertical, 14)
        .background(Color.earthCard)
        .cornerRadius(18)
        .padding(.horizontal, 20)
    }

    // MARK: - Actions

    private func loadMyProgress() async {
        switch challenge.goalType {
        case .steps:
            myProgressValue = await ChallengeService.shared.fetchSteps(for: challenge)
        case .distance, .pace:
            myProgressValue = challenge.localProgressValue(from: historyStore.sessions)
        }
    }

    private func loadLeaderboard() async {
        isLoading = true; loadError = nil
        do {
            participants = try await ChallengeService.shared.fetchLeaderboard(for: challenge)
        } catch {
            loadError = "Couldn't load leaderboard — check your connection."
        }
        isLoading = false
    }

    private func syncProgress() async {
        isSyncing = true; syncMessage = nil
        let value: Int
        switch challenge.goalType {
        case .steps:
            value = await ChallengeService.shared.fetchSteps(for: challenge)
        case .distance, .pace:
            value = challenge.localProgressValue(from: historyStore.sessions)
        }
        myProgressValue = value
        do {
            try await ChallengeService.shared.joinOrUpdate(challenge, steps: value)
            syncMessage = "Synced \(challenge.leaderboardDisplay(for: value)) ✓"
            await loadLeaderboard()
        } catch {
            syncMessage = "Sync failed — check your connection."
        }
        isSyncing = false
    }
}

// MARK: - Leaderboard Row

private struct LeaderboardRow: View {
    let rank:        Int
    let participant: ChallengeParticipant
    let challenge:   WalkChallenge

    private var progress: Double { challenge.progress(for: participant.steps) }
    private var medalEmoji: String? {
        switch rank {
        case 1: return "🥇"
        case 2: return "🥈"
        case 3: return "🥉"
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let medal = medalEmoji {
                    Text(medal).font(.title3)
                } else {
                    Text("#\(rank)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.earthMuted)
                        .frame(width: 28)
                }
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(participant.isCurrentDevice ? "You (\(participant.displayName))" : participant.displayName)
                        .font(.subheadline)
                        .foregroundColor(participant.isCurrentDevice ? .earthGreen : .earthCream)
                        .lineLimit(1)
                    if participant.isCurrentDevice {
                        Circle().fill(Color.earthGreen).frame(width: 5, height: 5)
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.earthMuted.opacity(0.1))
                        Capsule()
                            .fill(progress >= 1
                                ? Color.accentNotice
                                : (participant.isCurrentDevice ? Color.earthGreen : Color.earthGreen.opacity(0.55)))
                            .frame(width: max(3, geo.size.width * progress))
                    }
                    .frame(height: 4)
                }
                .frame(height: 4)
            }

            Text(challenge.leaderboardDisplay(for: participant.steps))
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(.earthCream)
                .frame(minWidth: 60, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Create Challenge View

struct CreateChallengeView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title    = ""
    @State private var emoji    = "🏆"
    @State private var duration = 7
    @State private var isSaving  = false
    @State private var saveError: String? = nil

    // Goal type
    @State private var goalType:      ChallengeGoalType = .steps
    @State private var activityFilter: String? = nil  // nil = any

    // Steps
    @State private var goalSteps = 50_000

    // Distance
    @State private var goalDistanceMeters = 10_000.0

    // Pace
    @State private var goalPaceSecsPerKm = 480.0  // 8:00/km
    @State private var goalSessionCount  = 3

    private let emojiOptions    = ["🏆", "🔥", "⚡️", "🌿", "🦅", "💪", "🌍", "🏃", "🎯", "🌟"]
    private let stepOptions     = [10_000, 25_000, 50_000, 75_000, 100_000, 150_000, 200_000]
    private let durationOptions = [3, 7, 14, 30]
    private let sessionCountOptions = [1, 3, 5, 7, 10]

    private var distanceOptions: [(meters: Double, label: String)] {
        let useMetric = Locale.current.measurementSystem != .us
        return useMetric
            ? [(5_000, "5 km"), (10_000, "10 km"), (20_000, "20 km"), (50_000, "50 km"), (100_000, "100 km")]
            : [(4_828, "3 mi"), (9_656, "6 mi"), (20_921, "13 mi"), (41_843, "26 mi"), (99_779, "62 mi")]
    }

    private let paceOptions: [(secsPerKm: Double, hint: String)] = [
        (300, "blazing 🔥"),
        (360, "race pace"),
        (420, "strong"),
        (480, "solid"),
        (540, "comfy"),
        (600, "any pace wins"),
    ]

    private let activityOptions: [(filter: String?, label: String, icon: String)] = [
        (nil,       "Any",   "sparkles"),
        ("walking", "Walk",  "figure.walk"),
        ("running", "Run",   "figure.run"),
        ("cycling", "Bike",  "figure.outdoor.cycle"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        titleSection
                        emojiSection
                        goalTypeSection
                        if goalType != .steps { activitySection }
                        goalValueSection
                        durationSection
                        if let err = saveError {
                            Text(err)
                                .font(.caption).foregroundColor(.earthOrange)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                        createButton
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("New Challenge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.earthMuted)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var titleSection: some View {
        formSection(title: "Challenge Name") {
            TextField("e.g. Weekend Runfest", text: $title)
                .foregroundColor(.earthCream)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Color.earthCard)
                .cornerRadius(12)
        }
    }

    private var emojiSection: some View {
        formSection(title: "Icon") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 10) {
                ForEach(emojiOptions, id: \.self) { e in
                    Button { emoji = e } label: {
                        Text(e)
                            .font(.system(size: 28))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(emoji == e ? Color.earthGreen.opacity(0.2) : Color.earthCard)
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(emoji == e ? Color.earthGreen.opacity(0.5) : Color.clear, lineWidth: 1.5)
                            )
                    }
                }
            }
        }
    }

    private var goalTypeSection: some View {
        formSection(title: "Goal Type") {
            HStack(spacing: 8) {
                ForEach(ChallengeGoalType.allCases, id: \.self) { type in
                    let selected = goalType == type
                    Button { goalType = type } label: {
                        VStack(spacing: 4) {
                            Text(goalTypeEmoji(type)).font(.system(size: 22))
                            Text(goalTypeLabel(type))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(selected ? .white : .earthCream)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(selected ? Color.earthGreenFill : Color.earthCard)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selected ? Color.earthGreen.opacity(0.5) : Color.clear, lineWidth: 1.5)
                        )
                    }
                }
            }
        }
    }

    private var activitySection: some View {
        formSection(title: "Activity") {
            HStack(spacing: 8) {
                ForEach(activityOptions, id: \.label) { opt in
                    let selected = activityFilter == opt.filter
                    Button { activityFilter = opt.filter } label: {
                        VStack(spacing: 4) {
                            Image(systemName: opt.icon).font(.system(size: 18))
                            Text(opt.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(selected ? .white : .earthCream)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(selected ? Color.earthGreenFill : Color.earthCard)
                        .foregroundColor(selected ? .white : .earthMuted)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selected ? Color.earthGreen.opacity(0.5) : Color.clear, lineWidth: 1.5)
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var goalValueSection: some View {
        switch goalType {
        case .steps:
            formSection(title: "Step Goal") {
                VStack(spacing: 8) {
                    ForEach(stepOptions, id: \.self) { g in
                        Button { goalSteps = g } label: {
                            HStack {
                                Text(formatK(g))
                                    .font(.subheadline.bold())
                                    .foregroundColor(goalSteps == g ? .white : .earthCream)
                                Spacer()
                                Text(approxStepTime(steps: g))
                                    .font(.caption)
                                    .foregroundColor(goalSteps == g ? .white.opacity(0.8) : .earthMuted)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .background(goalSteps == g ? Color.earthGreenFill : Color.earthCard)
                            .cornerRadius(10)
                        }
                    }
                }
            }
        case .distance:
            formSection(title: "Distance Goal") {
                VStack(spacing: 8) {
                    ForEach(distanceOptions, id: \.meters) { opt in
                        Button { goalDistanceMeters = opt.meters } label: {
                            HStack {
                                Text(opt.label)
                                    .font(.subheadline.bold())
                                    .foregroundColor(goalDistanceMeters == opt.meters ? .white : .earthCream)
                                Spacer()
                                Text(distanceHint(meters: opt.meters))
                                    .font(.caption)
                                    .foregroundColor(goalDistanceMeters == opt.meters ? .white.opacity(0.8) : .earthMuted)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .background(goalDistanceMeters == opt.meters ? Color.earthGreenFill : Color.earthCard)
                            .cornerRadius(10)
                        }
                    }
                }
            }
        case .pace:
            VStack(spacing: 24) {
                formSection(title: "Target Pace") {
                    VStack(spacing: 8) {
                        ForEach(paceOptions, id: \.secsPerKm) { opt in
                            Button { goalPaceSecsPerKm = opt.secsPerKm } label: {
                                HStack {
                                    Text(challengeFormattedPace(opt.secsPerKm))
                                        .font(.subheadline.bold())
                                        .foregroundColor(goalPaceSecsPerKm == opt.secsPerKm ? .white : .earthCream)
                                    Spacer()
                                    Text(opt.hint)
                                        .font(.caption)
                                        .foregroundColor(goalPaceSecsPerKm == opt.secsPerKm ? .white.opacity(0.8) : .earthMuted)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 11)
                                .background(goalPaceSecsPerKm == opt.secsPerKm ? Color.earthGreenFill : Color.earthCard)
                                .cornerRadius(10)
                            }
                        }
                    }
                }
                formSection(title: "Sessions Needed") {
                    HStack(spacing: 8) {
                        ForEach(sessionCountOptions, id: \.self) { n in
                            Button { goalSessionCount = n } label: {
                                Text("\(n)")
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(goalSessionCount == n ? Color.earthGreenFill : Color.earthCard)
                                    .foregroundColor(goalSessionCount == n ? .white : .earthCream)
                                    .cornerRadius(10)
                            }
                        }
                    }
                }
            }
        }
    }

    private var durationSection: some View {
        formSection(title: "Duration") {
            HStack(spacing: 8) {
                ForEach(durationOptions, id: \.self) { d in
                    Button { duration = d } label: {
                        Text("\(d)d")
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(duration == d ? Color.earthGreenFill : Color.earthCard)
                            .foregroundColor(duration == d ? .white : .earthCream)
                            .cornerRadius(10)
                    }
                }
            }
        }
    }

    private var createButton: some View {
        Button { Task { await save() } } label: {
            Group {
                if isSaving {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white).scaleEffect(0.85)
                        Text("Creating…")
                    }
                } else {
                    Label("Create Challenge", systemImage: "trophy.fill")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(title.trimmingCharacters(in: .whitespaces).isEmpty
                ? Color.earthGreenFill.opacity(0.45)
                : Color.earthGreenFill)
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
    }

    // MARK: - Helpers

    private func formSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.earthMuted)
                .textCase(.uppercase)
            content()
        }
    }

    private func save() async {
        isSaving = true; saveError = nil
        do {
            try await ChallengeService.shared.createChallenge(
                title:              title.trimmingCharacters(in: .whitespaces),
                emoji:              emoji,
                goalType:           goalType,
                activityFilter:     activityFilter,
                goalSteps:          goalSteps,
                goalDistanceMeters: goalDistanceMeters,
                goalPaceSecsPerKm:  goalPaceSecsPerKm,
                goalSessionCount:   goalSessionCount,
                durationDays:       duration
            )
            dismiss()
        } catch {
            saveError = "Couldn't create challenge — check your connection."
        }
        isSaving = false
    }

    private func goalTypeLabel(_ type: ChallengeGoalType) -> String {
        switch type {
        case .steps:    return "Steps"
        case .distance: return "Distance"
        case .pace:     return "Pace"
        }
    }

    private func goalTypeEmoji(_ type: ChallengeGoalType) -> String {
        switch type {
        case .steps:    return "🦶"
        case .distance: return "📏"
        case .pace:     return "⚡️"
        }
    }

    private func formatK(_ n: Int) -> String {
        n >= 1_000 ? "\(n / 1_000)K steps" : "\(n) steps"
    }

    private func approxStepTime(steps: Int) -> String {
        let mins = steps / 100
        if mins < 60 { return "~\(mins) min" }
        return "~\(mins / 60)h \(mins % 60)m"
    }

    private func distanceHint(meters: Double) -> String {
        let secsPerKm: Double
        switch activityFilter {
        case "running": secsPerKm = 360
        case "cycling": secsPerKm = 180
        default:        secsPerKm = 720
        }
        let totalMins = Int((meters / 1000) * secsPerKm) / 60
        if totalMins < 60 { return "~\(totalMins) min" }
        let h = totalMins / 60; let m = totalMins % 60
        return m == 0 ? "~\(h)h" : "~\(h)h \(m)m"
    }
}

// MARK: - WalkChallenge helpers

private extension WalkChallenge {
    func daysRemaining(from date: Date) -> Int {
        max(0, Calendar.current.dateComponents([.day], from: date, to: endDate).day ?? 0)
    }
}
