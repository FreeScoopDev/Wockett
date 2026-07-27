import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var stepManager: StepManager
    @ObservedObject var historyStore: WalkHistoryStore
    @ObservedObject var routeStore: CustomRouteStore
    var bannerStore = BannerStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isAddingAffirmation = false
    @State private var newAffirmation = ""
    @State private var seedMessage: String? = nil

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            List {
                // ── Tracking ──────────────────────────────────────
                Section("Tracking") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Data Source")
                            .font(.subheadline).foregroundColor(.earthCream)
                        Picker("", selection: $stepManager.trackingMode) {
                            ForEach(StepManager.TrackingMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: stepManager.trackingMode) { _, m in stepManager.switchTrackingMode(to: m) }
                        Text(stepManager.trackingMode == .healthKit
                             ? "Steps are pulled from Apple Health. HealthKit permission required."
                             : "Steps are counted by this app using the device's motion sensor.")
                            .font(.caption).foregroundColor(.earthMuted)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.earthCard)

                    if stepManager.trackingMode == .healthKit {
                        Button {
                            if let url = URL(string: "x-apple-health://") { UIApplication.shared.open(url) }
                        } label: {
                            Label("Open Apple Health", systemImage: "heart.text.square")
                                .foregroundColor(.earthGreen)
                        }
                        .listRowBackground(Color.earthCard)
                    }
                }

                // ── Motivational Banner ───────────────────────────
                Section("Motivational Banner") {
                    if bannerStore.userAffirmations.isEmpty && !isAddingAffirmation {
                        Text("Add personal affirmations that rotate in the banner alongside built-in quotes.")
                            .font(.caption).foregroundColor(.earthMuted)
                            .listRowBackground(Color.earthCard)
                    }
                    ForEach(bannerStore.userAffirmations, id: \.self) { affirmation in
                        Text(affirmation)
                            .font(.subheadline).foregroundColor(.earthCream)
                            .listRowBackground(Color.earthCard)
                    }
                    .onDelete { bannerStore.delete(at: $0) }

                    if isAddingAffirmation {
                        HStack(spacing: 8) {
                            TextField("Your affirmation…", text: $newAffirmation)
                                .foregroundColor(.earthCream)
                                .submitLabel(.done)
                                .onSubmit {
                                    bannerStore.add(newAffirmation)
                                    newAffirmation = ""
                                    isAddingAffirmation = false
                                }
                            Button("Add") {
                                bannerStore.add(newAffirmation)
                                newAffirmation = ""
                                isAddingAffirmation = false
                            }
                            .foregroundColor(.earthGreen)
                            .disabled(newAffirmation.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .listRowBackground(Color.earthCard)
                    } else {
                        Button {
                            isAddingAffirmation = true
                        } label: {
                            Label("Add Affirmation", systemImage: "plus")
                                .foregroundColor(.earthGreen)
                        }
                        .listRowBackground(Color.earthCard)
                    }
                }

                // ── About ─────────────────────────────────────────
                Section("About") {
                    HStack {
                        Text("Version").foregroundColor(.earthCream)
                        Spacer()
                        Text("\(appVersion) (\(buildNumber))").foregroundColor(.earthMuted)
                    }
                    .listRowBackground(Color.earthCard)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Troubleshooting").font(.subheadline).foregroundColor(.earthCream)
                        Group {
                            Text("• Steps not updating? Try switching Data Source to App Only and back to Apple Health.")
                            Text("• If Health permission was denied, go to Settings → Privacy → Health → Wockett to re-enable.")
                            Text("• Walk history and goals are stored on this device only.")
                        }
                        .font(.caption).foregroundColor(.earthMuted)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.earthCard)

                    Button {
                        if let url = URL(string: "mailto:support@wockett.app?subject=Wockett%20Feedback") {
                            openURL(url)
                        }
                    } label: {
                        Label("Send Feedback", systemImage: "envelope")
                            .foregroundColor(.earthGreen)
                    }
                    .listRowBackground(Color.earthCard)
                }

                // ── Developer ─────────────────────────────────────
                Section {
                    if stepManager.trackingMode == .healthKit {
                        Text("Calendar views read from Apple Health in this mode. Seeding will switch to App Only so test data is visible.")
                            .font(.caption).foregroundColor(.earthOrange)
                            .listRowBackground(Color.earthCard)
                    }

                    if let msg = seedMessage {
                        Text(msg)
                            .font(.caption).foregroundColor(.earthGreen)
                            .listRowBackground(Color.earthCard)
                    }

                    Button {
                        if stepManager.trackingMode == .healthKit {
                            stepManager.switchTrackingMode(to: .appOnly)
                        }
                        DevSeedStore.seedWalkSessions(into: historyStore)
                        DevSeedStore.seedCustomRoutes(into: routeStore)
                        StreakStore.shared.refresh(
                            sessions: historyStore.sessions,
                            todaySteps: stepManager.todaySteps,
                            dailyGoal: stepManager.currentGoal
                        )
                        let count = historyStore.sessions.filter { $0.routeName.hasPrefix("[TEST]") }.count
                        seedMessage = "Seeded \(count) sessions + 4 routes (App Only mode)"
                    } label: {
                        Label("Seed Test Data", systemImage: "wand.and.stars")
                            .foregroundColor(.earthGreen)
                    }
                    .listRowBackground(Color.earthCard)

                    Button(role: .destructive) {
                        DevSeedStore.clearTestSessions(from: historyStore)
                        DevSeedStore.clearTestRoutes(from: routeStore)
                        StreakStore.shared.refresh(
                            sessions: historyStore.sessions,
                            todaySteps: stepManager.todaySteps,
                            dailyGoal: stepManager.currentGoal
                        )
                        seedMessage = "Test data cleared"
                    } label: {
                        Label("Clear Test Data", systemImage: "trash")
                    }
                    .listRowBackground(Color.earthCard)
                } header: {
                    Text("Developer")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
