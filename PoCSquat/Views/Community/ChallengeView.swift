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
    @State private var showDetail        = false
    @State private var showCreate        = false
    /// Opens "New challenge" on arrival (the Community hub's Start a challenge).
    private let startCreating: Bool
    @State private var didStartCreating = false

    init(startCreating: Bool = false) {
        self.startCreating = startCreating
    }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            if isLoading && challenges.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().tint(.earthGreen)
                    Text("Loading challenges…")
                        .font(.wktBodyText).foregroundColor(.earthMuted)
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
                    Image(wkt: .add).wktIcon(.inline, tint: .earthGreen)
                }
                .accessibilityLabel("New challenge")
            }
        }
        .task { await load() }
        .onAppear {
            if startCreating, !didStartCreating {
                didStartCreating = true
                showCreate = true
            }
        }
        .sheet(isPresented: $showCreate, onDismiss: { Task { await load() } }) {
            CreateChallengeView()
        }
        // A push like every other Community detail. `selectedChallenge` is left
        // set on the way back so the page doesn't blank out mid-pop.
        .navigationDestination(isPresented: $showDetail) {
            if let challenge = selectedChallenge {
                ChallengeDetailView(challenge: challenge)
            }
        }
    }

    // MARK: - Helpers (ChallengesContentView)

    private var challengeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                headerBanner
                if challenges.isEmpty && !isLoading {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                } else {
                    LazyVStack(spacing: WktSpacing.betweenCards) {
                        ForEach(challenges) { challenge in
                            ChallengeCard(
                                challenge: challenge,
                                isJoined: ChallengeService.shared.hasJoined(challenge),
                                onHide: { challenges = CommunityModerationStore.shared.visible(challenges.filter { $0.id != challenge.id }) }
                            )
                            .onTapGesture { selectedChallenge = challenge; showDetail = true }
                        }
                    }
                }
                if let err = loadError {
                    Text(err)
                        .font(.wktLabel).foregroundColor(.earthOrange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, WktSpacing.screen)
            .padding(.top, 8)
            .padding(.bottom, WktSpacing.betweenSections)
        }
    }

    private var headerBanner: some View {
        HStack(spacing: 12) {
            WktIconBadge(symbol: .records)
            VStack(alignment: .leading, spacing: 2) {
                Text("Community Challenges")
                    .font(.wktCardTitle).foregroundColor(.earthCream)
                Text("Walk together, compete together")
                    .font(.wktBodyText).foregroundColor(.earthMuted)
            }
            Spacer()
        }
    }

    private var emptyState: some View {
        WktEmptyState(symbol: .finish, tint: .earthGreen,
                      title: "No active challenges yet",
                      message: "Tap + to create the first community challenge and invite others to join.")
    }

    private func errorView(_ message: String) -> some View {
        WktEmptyState(symbol: .cloudError, message: message, actionTitle: "Retry") {
            Task { await load() }
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
            loadError = "Couldn't load challenges. Check your connection and try again."
        }
        isLoading = false
    }

    private func ckErrorMessage(_ error: CKError) -> String {
        switch error.code {
        case .notAuthenticated:
            return "Sign in to iCloud in the Settings app to view challenges."
        case .networkUnavailable, .networkFailure:
            return "No internet connection. Check your connection and retry."
        // .invalidArguments is a missing queryable index (endDate on Challenge,
        // challengeRecordName on ChallengeEntry) and .unknownItem an undeployed
        // record type: both fixed in CloudKit Console, and the DEBUG print in
        // load() carries the error.
        case .invalidArguments, .unknownItem:
            return "Challenges aren't available right now. Please try again later."
        default:
            return "Couldn't reach iCloud. Please try again."
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
    @State private var report: CommunityReport?

    var body: some View {
        HStack(spacing: 14) {
            Text(challenge.emoji)
                .font(.system(size: 26)) // the creator's pick (data)
                .frame(width: 48, height: 48)
                .background(Color.earthGreen.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(challenge.title)
                        .font(.wktRowTitle)
                        .foregroundColor(.earthCream)
                        .lineLimit(1)
                    if isJoined {
                        WktStatusChip(text: "Joined", dot: .earthGreen)
                    }
                }
                HStack(spacing: 6) {
                    Text(challenge.goalText)
                        .foregroundColor(.earthMuted)
                    Text("·").foregroundColor(.earthMuted)
                    Text(challenge.timeRemainingText)
                        .foregroundColor(challenge.daysRemaining(from: Date()) <= 1 ? .earthOrange : .earthMuted)
                }
                .font(.wktLabel)
                Text("by \(challenge.authorName)")
                    .font(.wktLabel).foregroundColor(.earthMuted)
            }

            Spacer()

            Image(wkt: .chevronRight)
                .wktIcon(.inline, tint: .earthMuted)
        }
        .wktCard()
        .overlay {
            if isJoined {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.earthGreen.opacity(0.35), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            if let onHide {
                CommunityReportButton("Report Challenge") { report = CommunityReport(challenge: challenge) }
                CommunityBlockButton(author: challenge.author, onHide: onHide)
            }
        }
        .communityReporting($report, onHide: { _ in onHide?() })
    }
}

// MARK: - Challenge Detail View

struct ChallengeDetailView: View {
    let challenge: WalkChallenge
    @EnvironmentObject private var stepManager:  StepManager
    @EnvironmentObject private var historyStore: WalkHistoryStore

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
        ZStack {
            Color.earthBg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                    heroSection
                    syncSection
                    leaderboardSection
                }
                .padding(.horizontal, WktSpacing.screen)
                .padding(.top, 8)
                .padding(.bottom, WktSpacing.betweenSections)
            }
        }
        .navigationTitle(challenge.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadLeaderboard()
            await loadMyProgress()
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: WktSpacing.cardPadding) {
            HStack(spacing: 16) {
                Text(challenge.emoji)
                    .font(.system(size: 36)) // the creator's pick (data)
                    .frame(width: 64, height: 64)
                    .background(Color.earthGreen.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(challenge.goalText)
                        .font(.wktCardTitle.monospacedDigit())
                        .foregroundColor(.earthCream)
                    Text(challenge.timeRemainingText)
                        .font(.wktBodyText)
                        .foregroundColor(challenge.daysRemaining(from: Date()) <= 1 ? .earthOrange : .earthMuted)
                    Text(detailSubtitle)
                        .font(.wktLabel).foregroundColor(.earthMuted)
                }
                Spacer()
            }

            if isJoined || myProgressValue > 0 {
                WktDivider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Your progress")
                            .font(.wktLabel)
                            .foregroundColor(.earthMuted)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        if let rank = myRank {
                            WktStatusChip(text: "Rank #\(rank)", dot: .earthGreen)
                        }
                        Text(challenge.progressDisplay(for: myProgressValue))
                            .font(.wktLabel.monospacedDigit())
                            .foregroundColor(.earthCream)
                    }

                    let prog = challenge.progress(for: myProgressValue)
                    WktProgressBar(value: prog, tint: prog >= 1 ? .accentNotice : .earthGreen)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: prog)

                    if challenge.goalType == .pace {
                        Text("Qualifying sessions beat \(challengeFormattedPace(challenge.goalPaceSecsPerKm)) · \(challenge.activityFilterLabel)")
                            .font(.wktLabel).foregroundColor(.earthMuted)
                    }
                }
            }
        }
        .wktCard()
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
                if isSyncing {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white).scaleEffect(0.85)
                        Text("Syncing…")
                            .font(.wktHeading(17))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Color.earthGreenFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    WktPrimaryLabel(title: syncButtonLabel, symbol: isJoined ? .loop : .joinPerson)
                }
            }
            .buttonStyle(BounceButtonStyle(scale: 0.98))
            .disabled(isSyncing)

            if let msg = syncMessage {
                Text(msg)
                    .font(.wktLabel).foregroundColor(.earthGreen)
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

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: WktSpacing.betweenCards) {
            // WktSectionHeader's look, plus the trailing count or spinner it has no slot for.
            HStack(alignment: .firstTextBaseline) {
                Text("Leaderboard")
                    .font(.wktSection)
                    .foregroundColor(.earthCream)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if isLoading {
                    ProgressView().scaleEffect(0.7).tint(.earthGreen)
                } else {
                    Text("\(participants.count) participant\(participants.count == 1 ? "" : "s")")
                        .font(.wktLabel).foregroundColor(.earthMuted)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                if let err = loadError {
                    Text(err)
                        .font(.wktBodyText).foregroundColor(.earthOrange)
                } else if participants.isEmpty && !isLoading {
                    Text("Be the first to join this challenge!")
                        .font(.wktBodyText).foregroundColor(.earthMuted)
                } else {
                    ForEach(participants.indices, id: \.self) { i in
                        if i > 0 { WktDivider() }
                        LeaderboardRow(rank: i + 1, participant: participants[i], challenge: challenge)
                    }
                }
            }
            .wktCard()
        }
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
            syncMessage = "Synced \(challenge.leaderboardDisplay(for: value))"
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
    /// Gold, silver and bronze for the podium, from the app's palette.
    private var podiumTint: Color? {
        switch rank {
        case 1: return .accentNotice
        case 2: return .earthMuted
        case 3: return .earthOrange
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(podiumTint == nil ? "#\(rank)" : "\(rank)")
                .font(.wktLabel.monospacedDigit())
                .foregroundColor(podiumTint ?? .earthMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 24, height: 24)
                .background(Circle().fill((podiumTint ?? .clear).opacity(0.18)))
                .frame(width: 28)
                .accessibilityLabel("Rank \(rank)")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(participant.isCurrentDevice ? "You (\(participant.displayName))" : participant.displayName)
                        .font(.wktRowTitle)
                        .foregroundColor(participant.isCurrentDevice ? .earthGreen : .earthCream)
                        .lineLimit(1)
                    if participant.isCurrentDevice {
                        Circle().fill(Color.earthGreen).frame(width: 5, height: 5)
                    }
                }

                WktProgressBar(
                    value: progress,
                    tint: progress >= 1
                        ? .accentNotice
                        : (participant.isCurrentDevice ? .earthGreen : .earthGreen.opacity(0.55)),
                    height: 6
                )
            }

            Text(challenge.leaderboardDisplay(for: participant.steps))
                .font(.wktLabel.monospacedDigit())
                .foregroundColor(.earthCream)
                .frame(minWidth: 60, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
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
        (300, "blazing"),
        (360, "race pace"),
        (420, "strong"),
        (480, "solid"),
        (540, "comfy"),
        (600, "any pace wins"),
    ]

    private let activityOptions: [(filter: String?, label: String, icon: WktSymbol)] = [
        (nil,       "Any",   .anyActivity),
        ("walking", "Walk",  .walk),
        ("running", "Run",   .run),
        ("cycling", "Ride",  .ride),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                        titleSection
                        emojiSection
                        goalTypeSection
                        if goalType != .steps { activitySection }
                        goalValueSection
                        durationSection
                        if let err = saveError {
                            Text(err)
                                .font(.wktLabel).foregroundColor(.earthOrange)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                        createButton
                    }
                    .padding(.horizontal, WktSpacing.screen)
                    .padding(.top, 16)
                    .padding(.bottom, WktSpacing.betweenSections)
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
        formSection(title: "Challenge name") {
            TextField("e.g. Weekend Runfest", text: $title)
                .font(.wktBodyText)
                .foregroundColor(.earthCream)
                .padding(.horizontal, WktSpacing.cardPadding)
                .frame(minHeight: 52)
                .wktCardBackground()
        }
    }

    private var emojiSection: some View {
        formSection(title: "Icon") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 10) {
                ForEach(emojiOptions, id: \.self) { e in
                    Button { emoji = e } label: {
                        Text(e)
                            .font(.system(size: 28)) // emoji choices (data)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .wktChoiceBackground(selected: emoji == e)
                    }
                    .buttonStyle(BounceButtonStyle(scale: 0.95))
                    .accessibilityAddTraits(emoji == e ? .isSelected : [])
                }
            }
        }
    }

    private var goalTypeSection: some View {
        formSection(title: "Goal type") {
            HStack(spacing: 8) {
                ForEach(ChallengeGoalType.allCases, id: \.self) { type in
                    let selected = goalType == type
                    Button { goalType = type } label: {
                        VStack(spacing: 4) {
                            Image(wkt: goalTypeSymbol(type))
                                .wktIcon(.row, tint: selected ? .white : .earthMuted, onFill: selected)
                            Text(goalTypeLabel(type))
                                .font(.wktLabel)
                                .foregroundColor(selected ? .white : .earthCream)
                        }
                        .frame(maxWidth: .infinity, minHeight: 68)
                        .wktChoiceBackground(selected: selected)
                    }
                    .buttonStyle(BounceButtonStyle(scale: 0.96))
                    .accessibilityAddTraits(selected ? .isSelected : [])
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
                            Image(wkt: opt.icon)
                                .wktIcon(.row, tint: selected ? .white : .earthMuted, onFill: selected)
                            Text(opt.label)
                                .font(.wktLabel)
                                .foregroundColor(selected ? .white : .earthCream)
                        }
                        .frame(maxWidth: .infinity, minHeight: 68)
                        .wktChoiceBackground(selected: selected)
                    }
                    .buttonStyle(BounceButtonStyle(scale: 0.96))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder
    private var goalValueSection: some View {
        switch goalType {
        case .steps:
            formSection(title: "Step goal") {
                VStack(spacing: 8) {
                    ForEach(stepOptions, id: \.self) { g in
                        Button { goalSteps = g } label: {
                            HStack {
                                Text(formatK(g))
                                    .font(.wktRowTitle)
                                    .foregroundColor(goalSteps == g ? .white : .earthCream)
                                Spacer()
                                Text(approxStepTime(steps: g))
                                    .font(.wktLabel)
                                    .foregroundColor(goalSteps == g ? .white : .earthMuted)
                            }
                            .padding(.horizontal, WktSpacing.cardPadding)
                            .frame(minHeight: 52)
                            .wktChoiceBackground(selected: goalSteps == g)
                        }
                        .buttonStyle(BounceButtonStyle(scale: 0.98))
                        .accessibilityAddTraits(goalSteps == g ? .isSelected : [])
                    }
                }
            }
        case .distance:
            formSection(title: "Distance goal") {
                VStack(spacing: 8) {
                    ForEach(distanceOptions, id: \.meters) { opt in
                        Button { goalDistanceMeters = opt.meters } label: {
                            HStack {
                                Text(opt.label)
                                    .font(.wktRowTitle)
                                    .foregroundColor(goalDistanceMeters == opt.meters ? .white : .earthCream)
                                Spacer()
                                Text(distanceHint(meters: opt.meters))
                                    .font(.wktLabel)
                                    .foregroundColor(goalDistanceMeters == opt.meters ? .white : .earthMuted)
                            }
                            .padding(.horizontal, WktSpacing.cardPadding)
                            .frame(minHeight: 52)
                            .wktChoiceBackground(selected: goalDistanceMeters == opt.meters)
                        }
                        .buttonStyle(BounceButtonStyle(scale: 0.98))
                        .accessibilityAddTraits(goalDistanceMeters == opt.meters ? .isSelected : [])
                    }
                }
            }
        case .pace:
            VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                formSection(title: "Target pace") {
                    VStack(spacing: 8) {
                        ForEach(paceOptions, id: \.secsPerKm) { opt in
                            Button { goalPaceSecsPerKm = opt.secsPerKm } label: {
                                HStack {
                                    Text(challengeFormattedPace(opt.secsPerKm))
                                        .font(.wktRowTitle)
                                        .foregroundColor(goalPaceSecsPerKm == opt.secsPerKm ? .white : .earthCream)
                                    Spacer()
                                    Text(opt.hint)
                                        .font(.wktLabel)
                                        .foregroundColor(goalPaceSecsPerKm == opt.secsPerKm ? .white : .earthMuted)
                                }
                                .padding(.horizontal, WktSpacing.cardPadding)
                                .frame(minHeight: 52)
                                .wktChoiceBackground(selected: goalPaceSecsPerKm == opt.secsPerKm)
                            }
                            .buttonStyle(BounceButtonStyle(scale: 0.98))
                            .accessibilityAddTraits(goalPaceSecsPerKm == opt.secsPerKm ? .isSelected : [])
                        }
                    }
                }
                formSection(title: "Sessions needed") {
                    HStack(spacing: 8) {
                        ForEach(sessionCountOptions, id: \.self) { n in
                            Button { goalSessionCount = n } label: {
                                Text("\(n)")
                                    .font(.wktRowTitle)
                                    .foregroundColor(goalSessionCount == n ? .white : .earthCream)
                                    .frame(maxWidth: .infinity, minHeight: 52)
                                    .wktChoiceBackground(selected: goalSessionCount == n)
                            }
                            .buttonStyle(BounceButtonStyle(scale: 0.95))
                            .accessibilityAddTraits(goalSessionCount == n ? .isSelected : [])
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
                        Text("\(d) days")
                            .font(.wktLabel)
                            .foregroundColor(duration == d ? .white : .earthCream)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .wktChoiceBackground(selected: duration == d)
                    }
                    .buttonStyle(BounceButtonStyle(scale: 0.95))
                    .accessibilityAddTraits(duration == d ? .isSelected : [])
                }
            }
        }
    }

    private var createButton: some View {
        let blank = title.trimmingCharacters(in: .whitespaces).isEmpty
        return Button { Task { await save() } } label: {
            if isSaving {
                HStack(spacing: 8) {
                    ProgressView().tint(.white).scaleEffect(0.85)
                    Text("Creating…")
                        .font(.wktHeading(17))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color.earthGreenFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                WktPrimaryLabel(title: "Create Challenge", symbol: .records)
                    .opacity(blank ? 0.45 : 1)
            }
        }
        .buttonStyle(BounceButtonStyle(scale: 0.98))
        .disabled(blank || isSaving)
    }

    // MARK: - Helpers

    private func formSection<Content: View>(title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        WktSection(title: title, content: content)
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

    private func goalTypeSymbol(_ type: ChallengeGoalType) -> WktSymbol {
        switch type {
        case .steps:    return .steps
        case .distance: return .distance
        case .pace:     return .pace
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
