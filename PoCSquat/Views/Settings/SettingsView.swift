import SwiftUI
import UserNotifications
import UIKit
import EventKit

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var stepManager: StepManager
    var bannerStore: BannerStore = .shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isAddingAffirmation = false
    @State private var newAffirmation = ""

    @AppStorage("notif_weeklySummary")     private var weeklySummaryEnabled = true
    @AppStorage("notif_hydration")         private var hydrationEnabled = true
    @AppStorage("notif_streakProtection")  private var streakProtectionEnabled = true
    @AppStorage("walk_breakPromptMinutes") private var breakPromptMinutes = 3
    @State private var notifAuthorized = false
    @State private var showScheduleSheet = false

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

                    VStack(alignment: .leading, spacing: 6) {
                        Stepper(
                            "Break prompt after \(breakPromptMinutes) min",
                            value: $breakPromptMinutes,
                            in: 1...15
                        )
                        .foregroundColor(.earthCream)
                        Text("Shows a \"Still walking?\" prompt when no movement is detected for this long during an active walk.")
                            .font(.caption).foregroundColor(.earthMuted)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.earthCard)

                // ── Notifications ─────────────────────────────────
                Section("Notifications") {
                    HStack {
                        Label("Status", systemImage: "bell")
                            .foregroundColor(.earthCream)
                        Spacer()
                        Text(notifAuthorized ? "Enabled" : "Disabled")
                            .font(.caption)
                            .foregroundColor(notifAuthorized ? .earthGreen : .orange)
                    }
                    .listRowBackground(Color.earthCard)

                    if !notifAuthorized {
                        Button {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Enable in iOS Settings", systemImage: "arrow.up.right.square")
                                .foregroundColor(.earthGreen)
                        }
                        .listRowBackground(Color.earthCard)
                    }

                    Toggle(isOn: $weeklySummaryEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Weekly Activity Summary")
                                .foregroundColor(.earthCream)
                            Text("Sunday evening recap of steps, distance, and streak")
                                .font(.caption).foregroundColor(.earthMuted)
                        }
                    }
                    .tint(.earthGreen)
                    .disabled(!notifAuthorized)
                    .listRowBackground(Color.earthCard)

                    Toggle(isOn: $hydrationEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Post-walk Hydration Reminder")
                                .foregroundColor(.earthCream)
                            Text("Reminds you to drink water 5 minutes after finishing a walk")
                                .font(.caption).foregroundColor(.earthMuted)
                        }
                    }
                    .tint(.earthGreen)
                    .disabled(!notifAuthorized)
                    .listRowBackground(Color.earthCard)

                    Toggle(isOn: $streakProtectionEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Streak Protection Nudge")
                                .foregroundColor(.earthCream)
                            Text("4:30 PM reminder when you're still short of today's step goal")
                                .font(.caption).foregroundColor(.earthMuted)
                        }
                    }
                    .tint(.earthGreen)
                    .disabled(!notifAuthorized)
                    .listRowBackground(Color.earthCard)
                }

                // ── Walk Reminders ────────────────────────────────
                Section("Walk Reminders") {
                    let scheduler = WalkSchedulerService.shared
                    if scheduler.scheduledWalkEventIDs.isEmpty {
                        Text("Add recurring walk reminders to your Calendar with a 10-minute heads-up alert.")
                            .font(.caption).foregroundColor(.earthMuted)
                            .listRowBackground(Color.earthCard)
                    } else {
                        ForEach(Array(scheduler.scheduledWalkEventIDs.enumerated()), id: \.element) { idx, eventID in
                            HStack {
                                Label("Walk Reminder \(idx + 1)", systemImage: "calendar.badge.clock")
                                    .foregroundColor(.earthCream)
                                Spacer()
                                Button {
                                    scheduler.removeWalk(eventID: eventID)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                            .listRowBackground(Color.earthCard)
                        }
                    }
                    Button {
                        showScheduleSheet = true
                    } label: {
                        Label("Add Walk Reminder", systemImage: "calendar.badge.plus")
                            .foregroundColor(.earthGreen)
                    }
                    .listRowBackground(Color.earthCard)
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


            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showScheduleSheet) { WalkReminderSheet() }
        .task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            notifAuthorized = status == .authorized || status == .provisional
        }
    }
}

// MARK: - Schedule Walk Sheet

private struct WalkReminderSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title = "Morning Walk"
    @State private var startTime: Date = {
        Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: Date()) ?? Date()
    }()
    @State private var repeatOption: RepeatOption = .daily
    @State private var selectedWeekday: EKWeekday = .monday
    @State private var durationMinutes = 30
    @State private var isScheduling = false
    @State private var scheduleFailed = false

    enum RepeatOption: String, CaseIterable, Identifiable {
        case once   = "Once"
        case daily  = "Daily"
        case weekly = "Weekly"
        var id: String { rawValue }
    }

    private let durations = [15, 20, 30, 45, 60, 90]
    private let weekdays: [(String, EKWeekday)] = [
        ("Mon", .monday), ("Tue", .tuesday), ("Wed", .wednesday),
        ("Thu", .thursday), ("Fri", .friday), ("Sat", .saturday), ("Sun", .sunday)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                Form {
                    Section("Reminder") {
                        TextField("Title", text: $title)
                            .foregroundColor(.earthCream)
                            .listRowBackground(Color.earthCard)
                        DatePicker("Time", selection: $startTime, displayedComponents: .hourAndMinute)
                            .colorScheme(.dark)
                            .listRowBackground(Color.earthCard)
                    }

                    Section("Repeat") {
                        Picker("Frequency", selection: $repeatOption) {
                            ForEach(RepeatOption.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.earthCard)

                        if repeatOption == .weekly {
                            Picker("Day", selection: $selectedWeekday) {
                                ForEach(weekdays, id: \.1) { label, day in
                                    Text(label).tag(day)
                                }
                            }
                            .pickerStyle(.segmented)
                            .listRowBackground(Color.earthCard)
                        }
                    }

                    Section("Duration") {
                        Picker("Duration", selection: $durationMinutes) {
                            ForEach(durations, id: \.self) { Text("\($0) min").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.earthCard)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add Walk Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.earthGreen)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await schedule() }
                    } label: {
                        if isScheduling {
                            ProgressView().tint(.earthGreen)
                        } else {
                            Text("Add").bold().foregroundColor(.earthGreen)
                        }
                    }
                    .disabled(isScheduling || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Could not add reminder", isPresented: $scheduleFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please grant Wockett access to Calendar in iOS Settings → Privacy → Calendars.")
            }
        }
    }

    private func schedule() async {
        isScheduling = true
        let scheduler = WalkSchedulerService.shared

        // Resolve date: apply chosen time to today, roll to tomorrow if already past
        let comps = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        var target = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        target.hour   = comps.hour
        target.minute = comps.minute
        target.second = 0
        var date = Calendar.current.date(from: target) ?? Date()
        if date < Date() {
            date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
        }

        let rule: EKRecurrenceRule?
        switch repeatOption {
        case .once:   rule = nil
        case .daily:  rule = WalkSchedulerService.dailyRule()
        case .weekly: rule = WalkSchedulerService.weeklyRule(on: selectedWeekday)
        }

        let success = await scheduler.scheduleWalk(
            title: title.trimmingCharacters(in: .whitespaces),
            startDate: date,
            durationMinutes: durationMinutes,
            recurrenceRule: rule
        )
        isScheduling = false
        if success { dismiss() } else { scheduleFailed = true }
    }
}
