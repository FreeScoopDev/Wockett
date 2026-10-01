import SwiftUI
import MapKit

// MARK: - Activity Summary View
//
// Unified post-session summary shown for every in-app session end.
// Replaces WalkCompleteView (guided) and FreeWalkSummarySheet (free).

struct ActivitySummaryView: View {
    let session: WalkSession
    let newPRs: [PRType]
    let splits: [(label: String, elapsed: TimeInterval)]
    let petCompletions: [PetCompletion]
    let petNames: [String]
    var onExcludeFromRouteStats: (() -> Void)? = nil
    @ObservedObject var historyStore: WalkHistoryStore
    @ObservedObject var routeStore: CustomRouteStore

    @Environment(\.dismiss) private var dismiss

    @State private var excludedFromStats  = false
    @State private var savedAsRoute       = false
    @State private var showRouteNameField = false
    @State private var routeName          = ""
    @State private var showActivityShare  = false
    @State private var showScheduleSheet  = false
    @State private var ringProgress: [UUID: Double] = [:]

    private var mode: ActivityMode { ActivityMode(rawValue: session.activityType) ?? .walking }

    private var canSaveAsRoute: Bool {
        // Free session (no saved-route ID) with enough breadcrumb points.
        session.customRouteId == nil && session.waypoints.count > 5
    }

    private var completionMessage: String {
        switch petNames.count {
        case 0:  return "Nice work on \(session.routeName). Keep the momentum going!"
        case 1:  return "Nice work! \(petNames[0]) had a great \(mode.noun) too. 🐾"
        case 2:  return "Nice work! \(petNames[0]) and \(petNames[1]) loved it. 🐾"
        default: return "Nice work! The whole crew crushed it. 🐾"
        }
    }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            ConfettiOverlay()

            VStack(spacing: 0) {
                Spacer()
                // Header
                VStack(spacing: 12) {
                    WktIconBadge(symbol: mode.wktSymbol, size: 64)
                        .padding(.bottom, 4)
                    Text("\(mode.sessionLabel) complete!")
                        .font(.wktMetric)
                        .foregroundColor(.earthCream)
                        .multilineTextAlignment(.center)
                    Text(completionMessage)
                        .font(.wktBodyText)
                        .foregroundColor(.earthMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()

                ScrollView {
                    VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                        // Stats tiles
                        HStack(spacing: WktSpacing.betweenCards) {
                            statTile(value: session.distanceText, label: "Distance",
                                     icon: .distance, color: .earthGreen)
                            statTile(value: session.timeText, label: "Time",
                                     icon: .time, color: .earthOrange)
                            statTile(value: session.estimatedSteps.formatted(), label: "Steps",
                                     icon: mode.wktSymbol, color: mode.tileColor)
                        }

                        if !newPRs.isEmpty { prBanner }
                        if let line = stopEncouragement {
                            Text(line)
                                .font(.wktRowTitle).foregroundColor(.earthGreen)
                                .transition(.opacity)
                        }
                        if !petCompletions.isEmpty { petRingsSection }
                        if !splits.isEmpty { splitsSection }
                        if session.customRouteId != nil { routeStatsPrompt }

                        if canSaveAsRoute { saveAsRouteSection }

                        // Action buttons: Done is the one primary action.
                        VStack(spacing: WktSpacing.betweenCards) {
                            WktSecondaryButton(title: "Share this \(mode.noun)", symbol: .share) {
                                showActivityShare = true
                            }
                            WktSecondaryButton(title: "Schedule this \(mode.noun) again", symbol: .calendarAdd) {
                                showScheduleSheet = true
                            }
                            WktPrimaryButton(title: "Done") { dismiss() }
                                .accessibilityIdentifier("summary.done")
                        }
                    }
                    .padding(.horizontal, WktSpacing.screen)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary.root")
        .onAppear {
            for (i, c) in petCompletions.enumerated() {
                withAnimation(.spring(duration: 0.9, bounce: 0.25).delay(Double(i) * 0.18)) {
                    ringProgress[c.pet.id] = c.progress
                }
            }
        }
        .sheet(isPresented: $showActivityShare) {
            ActivitySummaryShareSheet(session: session, historyStore: historyStore)
        }
        .sheet(isPresented: $showScheduleSheet) {
            ScheduleWalkSheet(routeName: session.routeName)
        }
    }

    // MARK: - Subviews

    private func statTile(value: String, label: String, icon: WktSymbol, color: Color) -> some View {
        VStack(spacing: 8) {
            WktIconBadge(symbol: icon, tint: color)
            Text(value)
                .font(.wktRowTitle)
                .foregroundColor(.earthCream)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.wktLabel).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .wktCardBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }

    private var prBanner: some View {
        WktSection(title: "New personal record\(newPRs.count > 1 ? "s" : "")") {
            HStack(spacing: WktSpacing.betweenCards) {
                ForEach(newPRs) { pr in
                    VStack(spacing: 4) {
                        Text(pr.emoji).font(.title2) // the record's own emoji (data)
                        Text(pr.title)
                            .font(.wktLabel).foregroundColor(.earthCream)
                            .multilineTextAlignment(.center)
                        Text(pr.valueText)
                            .font(.wktRowTitle)
                            .foregroundColor(.earthOrange)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .wktCardBackground(fill: .earthCard)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.earthOrange.opacity(0.4), lineWidth: 1))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(pr.title): \(pr.valueText)")
                }
            }
        }
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private var petRingsSection: some View {
        WktSection(title: "Your crew's progress today") {
            HStack(spacing: 24) {
                ForEach(petCompletions, id: \.pet.id) { c in
                    let progress = ringProgress[c.pet.id] ?? 0
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .stroke(Color.earthTrack, lineWidth: 7)
                                .frame(width: 72, height: 72)
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(c.pet.accentColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                                .frame(width: 72, height: 72)
                                .rotationEffect(.degrees(-90))
                            Text(c.pet.displayEmoji).font(.title2) // the pet's own emoji (data)
                        }
                        Text(c.pet.name).font(.wktLabel).foregroundColor(.earthCream)
                        Text("\(Int(progress * 100))%").font(.wktLabel).foregroundColor(c.pet.accentColor)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(c.pet.name)
                    .accessibilityValue("\(Int(progress * 100))% of daily step goal")
                }
            }
            .frame(maxWidth: .infinity)
            .wktCard()
        }
    }

    private var splitsSection: some View {
        WktSection(title: "Splits") {
            VStack(spacing: 0) {
                ForEach(splits.indices, id: \.self) { i in
                    if i > 0 { WktDivider() }
                    HStack {
                        Text(splits[i].label).font(.wktRowTitle).foregroundColor(.earthCream)
                        Spacer()
                        Text(splitText(splits[i].elapsed)).font(.wktBodyText).foregroundColor(.earthCream)
                        if i > 0 {
                            Text("(+\(splitText(splits[i].elapsed - splits[i-1].elapsed)))")
                                .font(.wktLabel).foregroundColor(.earthMuted)
                        }
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
            }
            .wktCard(padding: 14)
        }
    }

    private var routeStatsPrompt: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(excludedFromStats ? "Excluded from route history" : "Counting toward \"\(session.routeName)\"")
                    .font(.wktRowTitle)
                    .foregroundColor(excludedFromStats ? .earthMuted : .earthCream)
                Text(excludedFromStats ? "This session won't appear in route runs" : "Tap exclude to skip route stats for this session")
                    .font(.wktLabel).foregroundColor(.earthMuted)
            }
            Spacer()
            if !excludedFromStats {
                WktPillButton(title: "Exclude", tint: .earthCream) {
                    excludedFromStats = true
                    onExcludeFromRouteStats?()
                }
            }
        }
        .wktCard()
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: excludedFromStats)
    }

    private var saveAsRouteSection: some View {
        Group {
            if showRouteNameField {
                HStack(spacing: 10) {
                    TextField("Route name…", text: $routeName)
                        .font(.wktBodyText)
                        .foregroundColor(.earthCream)
                        .padding(.horizontal, WktSpacing.cardPadding)
                        .frame(minHeight: 52)
                        .wktCardBackground()
                    WktPillButton(title: "Save") { saveAsRoute() }
                }
            } else {
                WktSecondaryButton(title: savedAsRoute ? "Saved as Custom Route" : "Save as Custom Route",
                                   symbol: savedAsRoute ? .success : .saved) {
                    if !savedAsRoute { showRouteNameField = true }
                }
                .disabled(savedAsRoute)
            }
        }
    }

    // MARK: - Helpers

    private var stopEncouragement: String? {
        guard let routeId = session.customRouteId,
              let currentStops = session.stopCount else { return nil }
        let prev = historyStore.sessions
            .filter { $0.customRouteId == routeId && $0.countsTowardRouteStats && $0.id != session.id }
            .sorted { $0.date > $1.date }.first
        guard let prev, let prevStops = prev.stopCount, currentStops < prevStops else { return nil }
        if session.totalDistance > 200, session.elapsedTime > 0,
           prev.totalDistance > 200, prev.elapsedTime > 0 {
            let currPace = session.elapsedTime / (session.totalDistance / 1000)
            let prevPace = prev.elapsedTime / (prev.totalDistance / 1000)
            if currPace < prevPace { return nil }
        }
        return "Fewer stops than last time!"
    }

    private func splitText(_ t: TimeInterval) -> String {
        let s = Int(t); let m = s / 60
        return m < 60 ? "\(m)m \(s % 60)s" : "\(m / 60)h \(m % 60)m"
    }

    private func saveAsRoute() {
        let name = routeName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "My \(mode.sessionLabel)" : routeName
        routeStore.save(CustomRoute(
            id: UUID(),
            name: name,
            waypoints: session.waypoints,
            totalDistance: session.totalDistance,
            isLoop: false,
            createdAt: Date(),
            activityMode: mode
        ))
        savedAsRoute = true
        showRouteNameField = false
    }
}
