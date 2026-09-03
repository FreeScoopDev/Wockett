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
                    Image(wkt: mode.wktSymbol)
                        .wktIcon(.tab, tint: .earthGreen, filled: true)
                        .padding(.bottom, 4)
                    Text("\(mode.sessionLabel) Complete!")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.earthCream)
                    Text(completionMessage)
                        .font(.subheadline)
                        .foregroundColor(.earthMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()

                ScrollView {
                    VStack(spacing: 20) {
                        // Stats tiles
                        HStack(spacing: 10) {
                            statTile(value: session.distanceText, label: "Distance",
                                     icon: .distance, color: .earthGreen)
                            statTile(value: session.timeText, label: "Time",
                                     icon: .time, color: .earthOrange)
                            statTile(value: session.estimatedSteps.formatted(), label: "Steps",
                                     icon: mode.wktSymbol, color: .earthCream)
                        }
                        .padding(.horizontal)

                        if !newPRs.isEmpty { prBanner }
                        if let line = stopEncouragement {
                            Text(line)
                                .font(.subheadline.bold()).foregroundColor(.earthGreen)
                                .padding(.horizontal)
                                .transition(.opacity)
                        }
                        if !petCompletions.isEmpty { petRingsSection }
                        if !splits.isEmpty { splitsSection }
                        if session.customRouteId != nil { routeStatsPrompt }

                        if canSaveAsRoute { saveAsRouteSection }

                        // Action buttons
                        VStack(spacing: 12) {
                            Button { showActivityShare = true } label: {
                                Label {
                                    Text("Share this \(mode.sessionLabel)")
                                } icon: {
                                    Image(wkt: .share).wktIcon(.row, tint: .earthCream)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18).padding(.horizontal, 20)
                                .background(Color.earthCard).foregroundColor(.earthCream)
                                .fontWeight(.semibold).cornerRadius(14)
                                .overlay(RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.earthGreen.opacity(0.4), lineWidth: 1.5))
                            }
                            Button { showScheduleSheet = true } label: {
                                Label {
                                    Text("Schedule This \(mode.sessionLabel) Again")
                                } icon: {
                                    Image(wkt: .calendarAdd).wktIcon(.row, tint: .earthCream)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18).padding(.horizontal, 20)
                                .background(Color.earthCard).foregroundColor(.earthCream)
                                .fontWeight(.semibold).cornerRadius(14)
                                .overlay(RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.earthGreen.opacity(0.4), lineWidth: 1.5))
                            }
                            Button { dismiss() } label: {
                                Text("Done")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 18).padding(.horizontal, 20)
                                    .background(Color.earthCard).foregroundColor(.earthCream)
                                    .cornerRadius(14)
                            }
                            .accessibilityIdentifier("summary.done")
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 32)
                    }
                    .padding(.top, 8)
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
            Image(wkt: icon).wktIcon(.row, tint: color)
            Text(value).font(.headline.bold()).foregroundColor(.earthCream)
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20)
        .background(Color.earthCard).cornerRadius(14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }

    private var prBanner: some View {
        VStack(spacing: 10) {
            Text("New Personal Record\(newPRs.count > 1 ? "s" : "")! 🏅")
                .font(.caption.bold()).foregroundColor(.earthOrange)
            HStack(spacing: 12) {
                ForEach(newPRs) { pr in
                    VStack(spacing: 4) {
                        Text(pr.emoji).font(.title2)
                        Text(pr.title)
                            .font(.system(size: 10, weight: .bold)).foregroundColor(.earthCream)
                        Text(pr.valueText)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.earthOrange)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Color.earthOrange.opacity(0.1)).cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.earthOrange.opacity(0.3), lineWidth: 1))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(pr.title): \(pr.valueText)")
                }
            }
        }
        .padding(.horizontal)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private var petRingsSection: some View {
        VStack(spacing: 12) {
            Text("Your crew's progress today")
                .font(.caption.bold()).foregroundColor(.earthMuted)
            HStack(spacing: 24) {
                ForEach(petCompletions, id: \.pet.id) { c in
                    let progress = ringProgress[c.pet.id] ?? 0
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .stroke(c.pet.accentColor.opacity(0.2), lineWidth: 7)
                                .frame(width: 72, height: 72)
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(c.pet.accentColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                                .frame(width: 72, height: 72)
                                .rotationEffect(.degrees(-90))
                            Text(c.pet.displayEmoji).font(.title2)
                        }
                        Text(c.pet.name).font(.caption2).foregroundColor(.earthMuted)
                        Text("\(Int(progress * 100))%").font(.caption.bold()).foregroundColor(c.pet.accentColor)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(c.pet.name)
                    .accessibilityValue("\(Int(progress * 100))% of daily step goal")
                }
            }
        }
        .padding(.vertical, 16)
    }

    private var splitsSection: some View {
        VStack(spacing: 8) {
            Text("Splits").font(.caption.bold()).foregroundColor(.earthMuted)
            VStack(spacing: 4) {
                ForEach(splits.indices, id: \.self) { i in
                    HStack {
                        Text(splits[i].label).font(.caption.bold()).foregroundColor(.earthCream)
                        Spacer()
                        Text(splitText(splits[i].elapsed)).font(.caption).foregroundColor(.earthMuted)
                        if i > 0 {
                            Text("(+\(splitText(splits[i].elapsed - splits[i-1].elapsed)))")
                                .font(.caption2).foregroundColor(.earthMuted.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Color.earthCard).cornerRadius(8)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private var routeStatsPrompt: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(excludedFromStats ? "Excluded from route history" : "Counting toward \"\(session.routeName)\"")
                    .font(.subheadline.bold())
                    .foregroundColor(excludedFromStats ? .earthMuted : .earthCream)
                Text(excludedFromStats ? "This session won't appear in route runs" : "Tap exclude to skip route stats for this session")
                    .font(.caption).foregroundColor(.earthMuted)
            }
            Spacer()
            if !excludedFromStats {
                Button("Exclude") {
                    excludedFromStats = true
                    onExcludeFromRouteStats?()
                }
                .font(.caption.bold()).foregroundColor(.earthMuted)
            }
        }
        .padding(14).background(Color.earthCard).cornerRadius(12).padding(.horizontal)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: excludedFromStats)
    }

    private var saveAsRouteSection: some View {
        Group {
            if showRouteNameField {
                HStack(spacing: 10) {
                    TextField("Route name…", text: $routeName)
                        .foregroundColor(.earthCream).padding(12)
                        .background(Color.earthCard).cornerRadius(10)
                    Button("Save") { saveAsRoute() }
                        .foregroundColor(.earthGreen).fontWeight(.semibold)
                }
                .padding(.horizontal)
            } else {
                Button { if !savedAsRoute { showRouteNameField = true } } label: {
                    Label {
                        Text(savedAsRoute ? "Saved as Custom Route" : "Save as Custom Route")
                    } icon: {
                        Image(wkt: savedAsRoute ? .success : .saved)
                            .wktIcon(.row, tint: savedAsRoute ? .earthGreen : .earthCream,
                                     filled: true)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Color.earthCard)
                    .foregroundColor(savedAsRoute ? .earthGreen : .earthCream)
                    .fontWeight(.semibold).cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.earthGreen.opacity(0.4), lineWidth: 1.5))
                }
                .disabled(savedAsRoute).padding(.horizontal)
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
