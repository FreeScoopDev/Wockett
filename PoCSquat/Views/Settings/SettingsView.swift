import SwiftUI
import UserNotifications
import UIKit

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject private var stepManager: StepManager
    var bannerStore: BannerStore = .shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isAddingAffirmation = false
    @State private var newAffirmation = ""

    @AppStorage("notif_weeklySummary")     private var weeklySummaryEnabled = true
    @AppStorage("notif_hydration")         private var hydrationEnabled = true
    @AppStorage("notif_streakProtection")  private var streakProtectionEnabled = true
    @AppStorage("notif_petNudge")          private var petNudgeEnabled = true
    @AppStorage("notif_untrackedWalk")     private var untrackedWalkEnabled = false
    @AppStorage("walk_breakPromptMinutes") private var breakPromptMinutes = 3
    @State private var notifAuthorized = false
    @State private var notifQuiet = false
    @State private var notifDenied = false
    @State private var showScheduleSheet = false

    #if DEBUG
    @EnvironmentObject private var petStore:      PetStore
    @EnvironmentObject private var historyStore:  WalkHistoryStore
    @EnvironmentObject private var routeStore:    CustomRouteStore
    @State private var devSeedMessage: String? = nil
    #endif

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
                            Label { Text("Open Apple Health") } icon: { Image(wkt: .openHealth).wktIcon(.row, tint: .earthGreen) }
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
                        Text("Shows a \"still moving?\" check-in when no movement is detected for this long during an active session.")
                            .font(.caption).foregroundColor(.earthMuted)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.earthCard)

                // ── Notifications ─────────────────────────────────
                Section("Notifications") {
                    HStack {
                        Label { Text("Status") } icon: { Image(wkt: .notifications).wktIcon(.row, tint: .earthCream) }
                            .foregroundColor(.earthCream)
                        Spacer()
                        Text(notifAuthorized ? "Enabled" : notifQuiet ? "Quiet — no alerts" : "Disabled")
                            .font(.caption)
                            .foregroundColor(notifAuthorized ? .earthGreen : notifQuiet ? .earthMuted : .orange)
                    }
                    .listRowBackground(Color.earthCard)

                    if !notifAuthorized {
                        if notifDenied {
                            // Only iOS Settings can reverse a denial.
                            Button {
                                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                Label { Text("Enable in iOS Settings") } icon: { Image(wkt: .openExternal).wktIcon(.row, tint: .earthGreen) }
                                    .foregroundColor(.earthGreen)
                            }
                            .listRowBackground(Color.earthCard)
                        } else {
                            // Never asked, or quiet delivery only: Wockett can prompt from here.
                            Button {
                                Task { await promptForAlerts() }
                            } label: {
                                Label { Text("Turn On Alerts") } icon: { Image(wkt: .notifications).wktIcon(.row, tint: .earthGreen) }
                                    .foregroundColor(.earthGreen)
                            }
                            .listRowBackground(Color.earthCard)
                        }
                    }

                    Toggle(isOn: $weeklySummaryEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Weekly Activity Summary")
                                .foregroundColor(.earthCream)
                            Text("Sunday evening recap of steps, distance, and streak")
                                .font(.caption).foregroundColor(.earthMuted)
                        }
                    }
                    .tint(.earthGreenFill)
                    .disabled(!(notifAuthorized || notifQuiet))
                    .listRowBackground(Color.earthCard)

                    Toggle(isOn: $hydrationEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Post-walk Hydration Reminder")
                                .foregroundColor(.earthCream)
                            Text("Reminds you to drink water 5 minutes after finishing a walk")
                                .font(.caption).foregroundColor(.earthMuted)
                        }
                    }
                    .tint(.earthGreenFill)
                    .disabled(!(notifAuthorized || notifQuiet))
                    .listRowBackground(Color.earthCard)

                    Toggle(isOn: $streakProtectionEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Streak Protection Nudge")
                                .foregroundColor(.earthCream)
                            Text("4:30 PM reminder when you're still short of today's step goal")
                                .font(.caption).foregroundColor(.earthMuted)
                        }
                    }
                    .tint(.earthGreenFill)
                    .disabled(!(notifAuthorized || notifQuiet))
                    .listRowBackground(Color.earthCard)

                    Toggle(isOn: $petNudgeEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pet Walk Nudge")
                                .foregroundColor(.earthCream)
                            Text("9 AM reminder when a pet hasn't been on a walk in a couple of days")
                                .font(.caption).foregroundColor(.earthMuted)
                        }
                    }
                    .tint(.earthGreenFill)
                    .disabled(!(notifAuthorized || notifQuiet))
                    .listRowBackground(Color.earthCard)

                    Toggle(isOn: $untrackedWalkEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Untracked Walk Nudge")
                                .foregroundColor(.earthCream)
                            Text("When you've walked without tracking it. Wockett checks a few times a day, so this arrives after the walk, not during it.")
                                .font(.caption).foregroundColor(.earthMuted)
                        }
                    }
                    .tint(.earthGreenFill)
                    .disabled(!(notifAuthorized || notifQuiet))
                    .listRowBackground(Color.earthCard)
                }

                // ── Walk Reminders ────────────────────────────────
                Section("Walk Reminders") {
                    let notifications = NotificationService.shared
                    if notifications.walkReminders.isEmpty {
                        Text("Get a notification when it's time to walk — once, daily, or on a chosen day each week.")
                            .font(.caption).foregroundColor(.earthMuted)
                            .listRowBackground(Color.earthCard)
                    } else {
                        ForEach(notifications.walkReminders) { reminder in
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(reminder.title).foregroundColor(.earthCream)
                                        Text(reminder.scheduleSummary())
                                            .font(.caption).foregroundColor(.earthMuted)
                                    }
                                } icon: { Image(wkt: .calendarClock).wktIcon(.row, tint: .earthCream) }
                                Spacer()
                                Button {
                                    notifications.removeWalkReminder(id: reminder.id)
                                } label: {
                                    Image(wkt: .discard)
                                        .wktIcon(.inline, tint: .red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Delete \(reminder.title) reminder")
                            }
                            .listRowBackground(Color.earthCard)
                        }
                    }
                    Button {
                        showScheduleSheet = true
                    } label: {
                        Label { Text("Add Walk Reminder") } icon: { Image(wkt: .calendarAdd).wktIcon(.row, tint: .earthGreen) }
                            .foregroundColor(.earthGreen)
                    }
                    .listRowBackground(Color.earthCard)
                }

                // Reminders an earlier version put in the user's Calendar. Shown only
                // while any remain, so they can still be deleted from here.
                let legacy = WalkSchedulerService.shared
                if !legacy.scheduledWalkEventIDs.isEmpty {
                    Section {
                        ForEach(Array(legacy.scheduledWalkEventIDs.enumerated()), id: \.element) { idx, eventID in
                            HStack {
                                Label { Text("Calendar Reminder \(idx + 1)") } icon: { Image(wkt: .calendar).wktIcon(.row, tint: .earthCream) }
                                    .foregroundColor(.earthCream)
                                Spacer()
                                Button {
                                    legacy.removeWalk(eventID: eventID)
                                } label: {
                                    Image(wkt: .discard)
                                        .wktIcon(.inline, tint: .red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Delete calendar reminder \(idx + 1)")
                            }
                            .listRowBackground(Color.earthCard)
                        }
                    } header: {
                        Text("Calendar Reminders")
                    } footer: {
                        Text("Added to your Calendar by an earlier version of Wockett. New reminders are notifications; these stay until you delete them.")
                            .font(.caption).foregroundColor(.earthMuted)
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
                            Label { Text("Add Affirmation") } icon: { Image(wkt: .add).wktIcon(.row, tint: .earthGreen) }
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
                        Label { Text("Send Feedback") } icon: { Image(wkt: .envelope).wktIcon(.row, tint: .earthGreen) }
                            .foregroundColor(.earthGreen)
                    }
                    .listRowBackground(Color.earthCard)
                }



                #if DEBUG
                // ── Developer ─────────────────────────────────────
                Section("Developer") {
                    Button {
                        DevSeedStore.seedScreenshotDemo(
                            history: historyStore, pets: petStore, routes: routeStore)
                        devSeedMessage = "Seeded. Dismiss Settings to see changes."
                    } label: {
                        Label { Text("Seed Screenshot Demo") } icon: { Image(wkt: .camera).wktIcon(.row, tint: .earthGreen) }
                            .foregroundColor(.earthGreen)
                    }
                    .listRowBackground(Color.earthCard)

                    Button {
                        DevSeedStore.clearScreenshotDemo(
                            history: historyStore, pets: petStore, routes: routeStore)
                        devSeedMessage = "Demo data cleared."
                    } label: {
                        Label { Text("Clear Demo Data") } icon: { Image(wkt: .discard).wktIcon(.row, tint: .red.opacity(0.75)) }
                            .foregroundColor(.red.opacity(0.75))
                    }
                    .listRowBackground(Color.earthCard)

                    Button {
                        DevSeedStore.seedWalkSessions(into: historyStore)
                        devSeedMessage = "Seeded [TEST] streak data."
                    } label: {
                        Label { Text("Seed [TEST] Streak Data") } icon: { Image(wkt: .calories).wktIcon(.row, tint: .earthMuted) }
                            .foregroundColor(.earthMuted)
                    }
                    .listRowBackground(Color.earthCard)

                    Button {
                        DevSeedStore.clearTestSessions(from: historyStore)
                        DevSeedStore.clearTestRoutes(from: routeStore)
                        devSeedMessage = "Cleared [TEST] data."
                    } label: {
                        Label { Text("Clear [TEST] Data") } icon: { Image(wkt: .discard).wktIcon(.row, tint: .red.opacity(0.55)) }
                            .foregroundColor(.red.opacity(0.55))
                    }
                    .listRowBackground(Color.earthCard)

                    if let msg = devSeedMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(.earthMuted)
                            .listRowBackground(Color.earthCard)
                    }
                }
                #endif

            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.root")
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showScheduleSheet) { WalkReminderSheet() }
        .task {
            NotificationService.shared.pruneExpiredWalkReminders()
            await refreshNotificationStatus()
        }
        .onChange(of: [weeklySummaryEnabled, hydrationEnabled, streakProtectionEnabled, petNudgeEnabled, untrackedWalkEnabled]) { old, new in
            // A toggle switched on while delivery is only quiet is the user asking
            // for alerts — the moment for the real prompt.
            if zip(old, new).contains(where: { !$0 && $1 }) { Task { await promptForAlerts() } }
        }
    }

    private func refreshNotificationStatus() async {
        let svc = NotificationService.shared
        await svc.refreshStatus()
        notifAuthorized = svc.isFullyAuthorized
        notifQuiet      = svc.authorizationStatus == .provisional
        notifDenied     = svc.authorizationStatus == .denied
    }

    private func promptForAlerts() async {
        guard !notifAuthorized else { return }
        await NotificationService.shared.requestFullAuthorization()
        await refreshNotificationStatus()
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
    /// `Calendar` weekday numbering: 1 = Sunday … 7 = Saturday.
    @State private var selectedWeekday = 2
    @State private var isScheduling = false
    @State private var scheduleFailed = false

    enum RepeatOption: String, CaseIterable, Identifiable {
        case once   = "Once"
        case daily  = "Daily"
        case weekly = "Weekly"
        var id: String { rawValue }
    }

    private let weekdays: [(String, Int)] = [
        ("Mon", 2), ("Tue", 3), ("Wed", 4), ("Thu", 5), ("Fri", 6), ("Sat", 7), ("Sun", 1)
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
                Text("Turn on notifications for Wockett in iOS Settings → Notifications.")
            }
        }
    }

    private func schedule() async {
        isScheduling = true
        let comps = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        let hour = comps.hour ?? 7, minute = comps.minute ?? 30

        let schedule: WalkReminder.Schedule
        switch repeatOption {
        case .once:
            // The chosen time today, or tomorrow if that has already passed.
            var date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
            if date < Date() { date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date }
            schedule = .once(date)
        case .daily:
            schedule = .daily(hour: hour, minute: minute)
        case .weekly:
            schedule = .weekly(weekday: selectedWeekday, hour: hour, minute: minute)
        }

        let reminder = WalkReminder(title: title.trimmingCharacters(in: .whitespaces), schedule: schedule)
        let success = await NotificationService.shared.addWalkReminder(reminder)
        isScheduling = false
        if success { dismiss() } else { scheduleFailed = true }
    }
}
