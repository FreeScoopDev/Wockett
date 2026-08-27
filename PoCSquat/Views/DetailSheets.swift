import SwiftUI
import MapKit
import EventKit

// MARK: - Goal Editor Sheet

struct GoalEditorSheet: View {
    @ObservedObject var stepManager: StepManager
    @Environment(\.dismiss) private var dismiss
    @State private var goalText = ""
    @State private var distText = ""
    @State private var mode     = 0  // 0 = Steps, 1 = Distance

    private var todayWeekday: Int { Calendar.current.component(.weekday, from: Date()) }

    private var orderedDays: [(Int, String)] {
        let all: [(Int, String)] = [
            (1, "Sunday"), (2, "Monday"), (3, "Tuesday"), (4, "Wednesday"),
            (5, "Thursday"), (6, "Friday"), (7, "Saturday")
        ]
        let idx = all.firstIndex(where: { $0.0 == todayWeekday }) ?? 0
        return Array(all[idx...] + all[..<idx])
    }

    private let stepPresets  = [5_000, 7_500, 10_000, 12_500, 15_000, 20_000]
    @State private var showTagCustomizer = false

    // MARK: - Locale-aware unit helpers

    private static var useMetric: Bool {
        Locale.current.measurementSystem == .metric
    }

    // steps per km ≈ 1312 (0.762 m/step); steps per mile ≈ 2112 (1609 m/mile ÷ 0.762)
    private static var stepsPerUnit: Double { useMetric ? 1312 : 2112 }

    private static var unitLabel: String { useMetric ? "km" : "mi" }

    private static var unitPresets: [Double] {
        useMetric ? [3, 5, 7.5, 10, 15, 20] : [2, 3, 5, 6, 8, 12]
    }

    private static func distString(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(value))"
            : String(format: "%.1f", value)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 28) {
                        Picker("", selection: $mode) {
                            Text("Steps").tag(0)
                            Text("Distance").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 28)

                        if mode == 0 {
                            Text("Set your daily step goal")
                                .font(.subheadline).foregroundColor(.earthMuted)

                            TextField("Steps", text: $goalText)
                                .keyboardType(.numberPad)
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .multilineTextAlignment(.center)
                                .foregroundColor(.earthCream)

                            let columns = [GridItem(.adaptive(minimum: 70))]
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(stepPresets, id: \.self) { p in
                                    Button {
                                        goalText = "\(p)"
                                        stepManager.dailyGoal = p
                                    } label: {
                                        Text(p >= 10_000 ? "\(p / 1000)K" : "\(p / 1000).5K")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 14).padding(.vertical, 8)
                                            .background(stepManager.dailyGoal == p ? Color.earthGreen : Color.earthCard)
                                            .foregroundColor(stepManager.dailyGoal == p ? .white : .earthCream)
                                            .cornerRadius(20)
                                    }
                                }
                            }
                        } else {
                            Text("Set your daily distance goal")
                                .font(.subheadline).foregroundColor(.earthMuted)

                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                TextField(Self.unitLabel, text: $distText)
                                    .keyboardType(.decimalPad)
                                    .font(.system(size: 48, weight: .bold, design: .rounded))
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.earthCream)
                                    .frame(maxWidth: 180)
                                Text(Self.unitLabel)
                                    .font(.title2.bold())
                                    .foregroundColor(.earthMuted)
                            }

                            let columns = [GridItem(.adaptive(minimum: 60))]
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(Self.unitPresets, id: \.self) { dist in
                                    let steps = Int(dist * Self.stepsPerUnit)
                                    Button {
                                        distText = Self.distString(dist)
                                        stepManager.dailyGoal = steps
                                    } label: {
                                        Text("\(Self.distString(dist)) \(Self.unitLabel)")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 14).padding(.vertical, 8)
                                            .background(stepManager.dailyGoal == steps ? Color.earthGreen : Color.earthCard)
                                            .foregroundColor(stepManager.dailyGoal == steps ? .white : .earthCream)
                                            .cornerRadius(20)
                                    }
                                }
                            }
                        }

                        // ── Custom Weekly Schedule ────────────────────────
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Custom Weekly Schedule")
                                        .font(.subheadline).foregroundColor(.earthCream)
                                    Text(stepManager.useCustomSchedule
                                         ? "Goals below override your default"
                                         : "Set different goals per day of week")
                                        .font(.caption).foregroundColor(.earthMuted)
                                }
                                Spacer()
                                Toggle("", isOn: $stepManager.useCustomSchedule)
                                    .labelsHidden().tint(.earthGreen)
                            }
                            .padding(14)

                            if stepManager.useCustomSchedule {
                                Divider().background(Color.earthMuted.opacity(0.2))

                                // Lock All / Unlock All header
                                let allLocked = orderedDays.allSatisfy { stepManager.lockedWeekdays.contains($0.0) }
                                HStack {
                                    Text("Tap 🔒 to preserve a day's goal when the default changes")
                                        .font(.caption2).foregroundColor(.earthMuted)
                                    Spacer()
                                    Button {
                                        if allLocked {
                                            stepManager.lockedWeekdays = []
                                        } else {
                                            // Snapshot each day's effective value before locking
                                            for (wd, _) in orderedDays {
                                                stepManager.weekdayGoals[wd] = stepManager.weekdayGoals[wd] ?? stepManager.dailyGoal
                                            }
                                            stepManager.lockedWeekdays = Set(orderedDays.map(\.0))
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: allLocked ? "lock.fill" : "lock.open")
                                            Text(allLocked ? "Unlock All" : "Lock All")
                                                .font(.caption.bold())
                                        }
                                        .foregroundColor(allLocked ? .earthGreen : .earthMuted)
                                    }
                                }
                                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)

                                ForEach(orderedDays, id: \.0) { (wd, name) in
                                    VStack(spacing: 0) {
                                        HStack(spacing: 8) {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(name)
                                                    .foregroundColor(wd == todayWeekday ? .earthGreen : .earthCream)
                                                    .font(.subheadline)
                                                if wd == todayWeekday {
                                                    Text("Today").font(.caption2).foregroundColor(.earthGreen)
                                                }
                                            }
                                            Spacer()
                                            TextField("steps", value: Binding(
                                                get: { stepManager.weekdayGoals[wd] ?? stepManager.dailyGoal },
                                                set: { stepManager.weekdayGoals[wd] = ($0 == 0) ? nil : $0 }
                                            ), format: .number)
                                            .keyboardType(.numberPad)
                                            .multilineTextAlignment(.trailing)
                                            .foregroundColor(.earthGreen)
                                            .frame(width: 90)

                                            Button {
                                                if stepManager.lockedWeekdays.contains(wd) {
                                                    stepManager.lockedWeekdays.remove(wd)
                                                } else {
                                                    // Snapshot the current effective value before locking
                                                    stepManager.weekdayGoals[wd] = stepManager.weekdayGoals[wd] ?? stepManager.dailyGoal
                                                    stepManager.lockedWeekdays.insert(wd)
                                                }
                                            } label: {
                                                Image(systemName: stepManager.lockedWeekdays.contains(wd) ? "lock.fill" : "lock.open")
                                                    .font(.subheadline)
                                                    .foregroundColor(stepManager.lockedWeekdays.contains(wd) ? .earthGreen : .earthMuted.opacity(0.4))
                                            }
                                            .frame(width: 28)
                                        }
                                        .padding(.horizontal, 14).padding(.vertical, 10)

                                        // Activity tag chips — clipped so they respect card edge
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 6) {
                                                ForEach(stepManager.tagConfigs) { config in
                                                    let selected = stepManager.weekdayTags[wd] == config.id
                                                    Button {
                                                        stepManager.weekdayTags[wd] = selected ? nil : config.id
                                                    } label: {
                                                        HStack(spacing: 3) {
                                                            Text(config.emoji).font(.system(size: 10))
                                                            Text(config.name).font(.caption2.bold())
                                                        }
                                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                                        .background(selected ? config.color : Color.earthBg)
                                                        .foregroundColor(selected ? .white : config.color)
                                                        .cornerRadius(20)
                                                    }
                                                }
                                            }
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 2)
                                        }
                                        .clipped()
                                        .padding(.bottom, 10)
                                    }

                                    if wd != orderedDays.last?.0 {
                                        Divider().background(Color.earthMuted.opacity(0.15)).padding(.horizontal, 14)
                                    }
                                }
                            }
                        }
                        .background(Color.earthCard)
                        .cornerRadius(12)
                        .animation(.easeInOut(duration: 0.22), value: stepManager.useCustomSchedule)

                        // ── Customize Tags ───────────────────────────────
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Customize Tags")
                                        .font(.subheadline).foregroundColor(.earthCream)
                                    Text("Change emoji and color for each activity")
                                        .font(.caption).foregroundColor(.earthMuted)
                                }
                                Spacer()
                                Button { showTagCustomizer.toggle() } label: {
                                    Image(systemName: showTagCustomizer ? "chevron.up" : "chevron.down")
                                        .font(.caption).foregroundColor(.earthMuted.opacity(0.7))
                                }
                            }
                            .padding(14)

                            if showTagCustomizer {
                                Divider().background(Color.earthMuted.opacity(0.2))
                                ForEach($stepManager.tagConfigs) { $config in
                                    VStack(spacing: 0) {
                                        HStack(spacing: 10) {
                                            // Emoji field
                                            TextField("", text: $config.emoji)
                                                .font(.system(size: 22))
                                                .frame(width: 36)
                                                .multilineTextAlignment(.center)

                                            // Name field — 12 char limit
                                            TextField("Name", text: Binding(
                                                get: { config.name },
                                                set: { config.name = String($0.prefix(12)) }
                                            ))
                                            .font(.subheadline.bold())
                                            .foregroundColor(.earthCream)
                                            .frame(maxWidth: 80)

                                            Spacer()

                                            // Color palette — checkmark on selected
                                            HStack(spacing: 6) {
                                                ForEach(0..<ActivityTagConfig.palette.count, id: \.self) { i in
                                                    Button { withAnimation(.spring(duration: 0.2)) { config.colorIndex = i } } label: {
                                                        ZStack {
                                                            Circle()
                                                                .fill(ActivityTagConfig.palette[i])
                                                                .frame(width: config.colorIndex == i ? 26 : 20,
                                                                       height: config.colorIndex == i ? 26 : 20)
                                                                .shadow(color: config.colorIndex == i
                                                                    ? ActivityTagConfig.palette[i].opacity(0.55) : .clear,
                                                                    radius: 4, y: 2)
                                                            if config.colorIndex == i {
                                                                Image(systemName: "checkmark")
                                                                    .font(.system(size: 9, weight: .bold))
                                                                    .foregroundColor(.white)
                                                            }
                                                        }
                                                    }
                                                    .animation(.spring(duration: 0.2), value: config.colorIndex)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 14).padding(.vertical, 10)
                                        if config.id != stepManager.tagConfigs.last?.id {
                                            Divider().background(Color.earthMuted.opacity(0.12)).padding(.horizontal, 14)
                                        }
                                    }
                                }
                            }
                        }
                        .background(Color.earthCard)
                        .cornerRadius(12)
                        .animation(.easeInOut(duration: 0.22), value: showTagCustomizer)
                    }
                    .padding(28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Daily Goal")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                goalText = "\(stepManager.dailyGoal)"
                let units = Double(stepManager.dailyGoal) / Self.stepsPerUnit
                distText = Self.distString(units)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if mode == 0 {
                            if let v = Int(goalText), v > 0 { stepManager.dailyGoal = v }
                        } else {
                            if let units = Double(distText), units > 0 {
                                stepManager.dailyGoal = Int(units * Self.stepsPerUnit)
                            }
                        }
                        dismiss()
                    }.foregroundColor(.earthGreen)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.earthMuted)
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Day Detail Sheet

struct DayDetailSheet: View {
    let day: CalendarDay
    let sessions: [WalkSession]
    @Environment(\.dismiss) private var dismiss
    @State private var reminderScheduled = false
    @State private var showReminderError = false

    private static let fullDateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .full; return f
    }()

    private var daySessions: [WalkSession] {
        sessions.filter { Calendar.current.isDate($0.date, inSameDayAs: day.date) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        // Ring — circles are inset by stroke/2 so they don't clip
                        ZStack {
                            Circle()
                                .stroke(Color.earthMuted.opacity(0.15), lineWidth: 14)
                                .padding(7)
                            if !day.isFuture && day.progress > 0 {
                                Circle()
                                    .trim(from: 0, to: day.progress)
                                    .stroke(
                                        LinearGradient(colors: [.earthGreen, .earthOrange],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                                    )
                                    .rotationEffect(.degrees(-90))
                                    .padding(7)
                            }
                            VStack(spacing: 4) {
                                if let steps = day.steps {
                                    Text(steps.formatted())
                                        .font(.system(size: 38, weight: .bold, design: .rounded))
                                        .foregroundColor(.earthCream)
                                    Text("/ \(day.goal.formatted())")
                                        .font(.caption).foregroundColor(.earthMuted)
                                } else if day.isFuture {
                                    Text(day.goal.formatted())
                                        .font(.system(size: 32, weight: .bold, design: .rounded))
                                        .foregroundColor(.earthMuted.opacity(0.5))
                                    Text("planned")
                                        .font(.caption).foregroundColor(.earthMuted.opacity(0.4))
                                } else {
                                    Text("—")
                                        .font(.system(size: 38, weight: .bold, design: .rounded))
                                        .foregroundColor(.earthMuted.opacity(0.4))
                                    Text("no data")
                                        .font(.caption).foregroundColor(.earthMuted.opacity(0.4))
                                }
                            }
                        }
                        .frame(width: 180, height: 180)

                        // Tag + accomplishment badge
                        HStack(spacing: 10) {
                            if let emoji = day.tagEmoji, let color = day.tagColor, let tag = day.tag {
                                HStack(spacing: 5) {
                                    Text(emoji)
                                    Text(tag)
                                }
                                .font(.caption.bold())
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(color.opacity(0.15))
                                .foregroundColor(color)
                                .cornerRadius(20)
                            }
                            if day.isFuture {
                                Label("Scheduled", systemImage: "calendar.badge.clock")
                                    .font(.caption.bold()).foregroundColor(.earthMuted)
                            } else if let met = day.goalMet {
                                Label(met ? "Goal achieved" : "Goal not met",
                                      systemImage: met ? "checkmark.seal.fill" : "xmark.circle")
                                    .font(.caption.bold())
                                    .foregroundColor(met ? .earthGreen : .earthMuted)
                            }
                        }

                        // Stats row — always show goal; add steps/progress for non-future days
                        HStack(spacing: 0) {
                            statCell(label: "Goal", value: day.goal.formatted())
                            if let steps = day.steps {
                                Divider().frame(height: 40)
                                statCell(label: "Steps", value: steps.formatted())
                                Divider().frame(height: 40)
                                statCell(label: "Progress", value: "\(Int(day.progress * 100))%")
                                Divider().frame(height: 40)
                                statCell(label: "Distance", value: Self.formatDist(Double(steps) * 0.762))
                            }
                        }
                        .padding(.vertical, 8)
                        .background(Color.earthCard)
                        .cornerRadius(14)
                        .padding(.horizontal)

                        // Reminder button for future days
                        if day.isFuture {
                            Button {
                                Task { await scheduleReminder() }
                            } label: {
                                Label(
                                    reminderScheduled ? "Added to Reminders" : "Add to Reminders",
                                    systemImage: reminderScheduled ? "checkmark.circle.fill" : "bell.badge.plus"
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(reminderScheduled ? Color.earthCard : Color.earthGreen)
                                .foregroundColor(reminderScheduled ? .earthGreen : .white)
                                .fontWeight(.semibold)
                                .cornerRadius(12)
                            }
                            .disabled(reminderScheduled)
                            .padding(.horizontal)
                            .alert("Couldn't Add Reminder", isPresented: $showReminderError) {
                                Button("OK", role: .cancel) {}
                            } message: {
                                Text("Please allow Reminders access in Settings to use this feature.")
                            }
                        }

                        // Walk sessions
                        if !daySessions.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Walks").font(.caption.bold()).foregroundColor(.earthMuted)
                                    .padding(.horizontal, 20)
                                ForEach(daySessions) { session in
                                    sessionRow(session)
                                }
                            }
                        } else if !day.isFuture {
                            Text("No walks recorded this day")
                                .font(.caption).foregroundColor(.earthMuted.opacity(0.6))
                        }
                    }
                    .padding(.vertical, 24)
                }
            }
            .navigationTitle(Self.fullDateFmt.string(from: day.date))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.earthGreen)
                }
            }
        }
        .presentationDetents([.large])
    }

    @MainActor
    private func scheduleReminder() async {
        let store = EKEventStore()
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToReminders()
        } catch {
            showReminderError = true
            return
        }
        guard granted else { showReminderError = true; return }
        do {
            let reminder = EKReminder(eventStore: store)
            reminder.title = "Time for your walk! Goal: \(day.goal.formatted()) steps"
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: day.date)
            comps.hour = 8; comps.minute = 0
            reminder.dueDateComponents = comps
            reminder.calendar = store.defaultCalendarForNewReminders()
            try store.save(reminder, commit: true)
            reminderScheduled = true
            if let url = URL(string: "x-apple-reminder://") {
                await UIApplication.shared.open(url)
            }
        } catch {
            showReminderError = true
        }
    }

    private static func formatDist(_ meters: Double) -> String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: meters)
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.headline.monospacedDigit()).foregroundColor(.earthCream)
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private func sessionRow(_ session: WalkSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.routeName)
                    .font(.subheadline).foregroundColor(.earthCream)
                HStack(spacing: 12) {
                    Label(session.distanceText, systemImage: "ruler")
                    Label(session.timeText, systemImage: "clock")
                }
                .font(.caption).foregroundColor(.earthMuted)
            }
            Spacer()
            Text("\(session.estimatedSteps.formatted()) steps")
                .font(.caption.bold()).foregroundColor(.earthGreen)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.earthCard)
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - User Step Detail Sheet

struct UserStepDetailSheet: View {
    @ObservedObject var stepManager: StepManager
    @ObservedObject var historyStore: WalkHistoryStore
    @Environment(\.dismiss) private var dismiss

    private var recentSessions: [WalkSession] {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return historyStore.sessions.filter { $0.date >= cutoff }
    }

    private var weeklySteps: Int { recentSessions.reduce(0) { $0 + $1.estimatedSteps } }
    private var weeklyDistance: Double { recentSessions.reduce(0) { $0 + $1.totalDistance } }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        ZStack {
                            Circle()
                                .stroke(Color.earthMuted.opacity(0.15), lineWidth: 18)
                                .frame(width: 160, height: 160)
                            Circle()
                                .trim(from: 0, to: stepManager.progress)
                                .stroke(
                                    LinearGradient(colors: [.earthGreen, .earthOrange], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    style: StrokeStyle(lineWidth: 18, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                                .frame(width: 160, height: 160)
                                .animation(.easeInOut(duration: 0.6), value: stepManager.progress)
                            VStack(spacing: 2) {
                                Text("\(Int(stepManager.progress * 100))%")
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .foregroundColor(.earthCream)
                                Text("of goal")
                                    .font(.caption).foregroundColor(.earthMuted)
                            }
                        }
                        .padding(.top, 8)

                        HStack(spacing: 12) {
                            detailTile(value: stepManager.todaySteps.formatted(), label: "Steps Today", icon: "figure.walk", color: .earthGreen)
                            detailTile(value: stepManager.currentGoal.formatted(), label: "Daily Goal", icon: "flag.fill", color: .earthOrange, subtitle: {
                                let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
                                return "≈ \(f.string(fromDistance: Double(stepManager.currentGoal) * 0.762))"
                            }())
                        }
                        .padding(.horizontal)

                        HStack(spacing: 12) {
                            detailTile(value: stepManager.remainingSteps.formatted(), label: "Remaining", icon: "arrow.right.circle", color: .earthMuted)
                            let f = MKDistanceFormatter(); let _ = f.unitStyle = .abbreviated
                            detailTile(value: f.string(fromDistance: stepManager.remainingMeters), label: "Distance Left", icon: "ruler", color: .earthMuted)
                        }
                        .padding(.horizontal)

                        if !recentSessions.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Last 7 Days")
                                    .font(.headline).foregroundColor(.earthCream)
                                    .padding(.horizontal)

                                HStack(spacing: 12) {
                                    detailTile(value: weeklySteps.formatted(), label: "Steps", icon: "figure.walk", color: .earthGreen)
                                    let df = MKDistanceFormatter(); let _ = df.unitStyle = .abbreviated
                                    detailTile(value: df.string(fromDistance: weeklyDistance), label: "Distance", icon: "ruler", color: .earthGreen)
                                }
                                .padding(.horizontal)

                                ForEach(recentSessions.prefix(5)) { session in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(session.routeName).font(.subheadline).foregroundColor(.earthCream).lineLimit(1)
                                            Text(session.formattedDate).font(.caption).foregroundColor(.earthMuted)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(session.distanceText).font(.subheadline.bold()).foregroundColor(.earthGreen)
                                            Text("\(session.estimatedSteps.formatted()) steps").font(.caption).foregroundColor(.earthMuted)
                                        }
                                    }
                                    .padding(.horizontal).padding(.vertical, 8)
                                    .background(Color.earthCard).cornerRadius(10)
                                    .padding(.horizontal)
                                }
                            }
                        }
                        Spacer(minLength: 32)
                    }
                }
            }
            .navigationTitle("Your Progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.earthGreen)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func detailTile(value: String, label: String, icon: String, color: Color, subtitle: String? = nil) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(color).font(.title3)
            Text(value).font(.headline.bold()).foregroundColor(.earthCream)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundColor(.earthMuted)
            }
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .background(Color.earthCard).cornerRadius(14)
    }
}

// MARK: - Pet Detail Sheet

struct PetDetailSheet: View {
    let pet: PetProfile
    @ObservedObject var petStore: PetStore
    @ObservedObject var historyStore: WalkHistoryStore
    let onEdit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showEditor = false

    private var todaySteps: Int { petStore.todaySteps(for: pet, in: historyStore.sessions) }
    private var progress: Double { min(1.0, Double(todaySteps) / Double(max(1, pet.goalSteps))) }
    private var totalWalks: Int { petStore.totalWalks(for: pet, in: historyStore.sessions) }
    private var totalDist: Double { petStore.totalDistance(for: pet, in: historyStore.sessions) }
    private var streak: Int { petStore.walkStreak(for: pet, in: historyStore.sessions) }
    private var weeklySteps: Int { petStore.weeklySteps(for: pet, in: historyStore.sessions) }
    private var weeklyDist: Double { petStore.weeklyDistance(for: pet, in: historyStore.sessions) }
    private var recentSessions: [WalkSession] { petStore.recentSessions(for: pet, in: historyStore.sessions) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        ZStack {
                            Circle()
                                .stroke(pet.accentColor.opacity(0.2), lineWidth: 18)
                                .frame(width: 160, height: 160)
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(pet.accentColor, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 160, height: 160)
                                .animation(.easeInOut(duration: 0.7), value: progress)
                            VStack(spacing: 4) {
                                Text(pet.displayEmoji).font(.system(size: 40))
                                Text("\(Int(progress * 100))%")
                                    .font(.system(size: 22, weight: .bold, design: .rounded))
                                    .foregroundColor(.earthCream)
                            }
                        }
                        .padding(.top, 8)

                        Text(pet.name)
                            .font(.title2.bold()).foregroundColor(.earthCream)
                        if let breed = pet.breed {
                            Text(breed).font(.subheadline).foregroundColor(.earthMuted)
                        }

                        HStack(spacing: 12) {
                            detailTile(value: todaySteps.formatted(), label: "Steps Today", icon: "figure.walk", color: pet.accentColor)
                            detailTile(value: pet.goalSteps.formatted(), label: "Daily Goal", icon: "flag.fill", color: .earthMuted)
                        }
                        .padding(.horizontal)

                        HStack(spacing: 12) {
                            detailTile(value: "\(totalWalks)", label: "Total Walks", icon: "clock.arrow.circlepath", color: .earthGreen)
                            detailTile(value: MKDistanceFormatter.abbreviated.string(fromDistance: totalDist), label: "Total Distance", icon: "ruler", color: .earthGreen)
                        }
                        .padding(.horizontal)

                        HStack(spacing: 12) {
                            detailTile(value: streak > 0 ? "\(streak)d" : "—", label: "Walk Streak", icon: "flame.fill", color: streak > 0 ? .earthOrange : .earthMuted)
                            detailTile(value: "\(recentSessions.count)", label: "Walks This Week", icon: "calendar", color: .earthMuted)
                        }
                        .padding(.horizontal)

                        if !recentSessions.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Last 7 Days")
                                    .font(.headline).foregroundColor(.earthCream)
                                    .padding(.horizontal)

                                HStack(spacing: 12) {
                                    detailTile(value: weeklySteps.formatted(), label: "Steps", icon: "figure.walk", color: pet.accentColor)
                                    detailTile(value: MKDistanceFormatter.abbreviated.string(fromDistance: weeklyDist), label: "Distance", icon: "ruler", color: pet.accentColor)
                                }
                                .padding(.horizontal)

                                ForEach(recentSessions.prefix(5)) { session in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(session.routeName).font(.subheadline).foregroundColor(.earthCream).lineLimit(1)
                                            Text(session.formattedDate).font(.caption).foregroundColor(.earthMuted)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(session.distanceText).font(.subheadline.bold()).foregroundColor(pet.accentColor)
                                            Text("\(session.estimatedSteps.formatted()) steps").font(.caption).foregroundColor(.earthMuted)
                                        }
                                    }
                                    .padding(.horizontal).padding(.vertical, 8)
                                    .background(Color.earthCard).cornerRadius(10)
                                    .padding(.horizontal)
                                }
                            }
                        }

                        Spacer(minLength: 32)
                    }
                }
            }
            .navigationTitle(pet.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Edit") { showEditor = true }.foregroundColor(.earthGreen)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.earthMuted)
                }
            }
            .sheet(isPresented: $showEditor) {
                PetEditorSheet(pet: pet, defaultGoal: pet.goalSteps) { updated in
                    petStore.update(updated)
                    dismiss()
                } onDelete: {
                    petStore.remove(id: pet.id)
                    dismiss()
                }
            }
        }
        .presentationDetents([.large])
    }

    private func detailTile(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(color).font(.title3)
            Text(value).font(.headline.bold()).foregroundColor(.earthCream)
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .background(Color.earthCard).cornerRadius(14)
    }
}
