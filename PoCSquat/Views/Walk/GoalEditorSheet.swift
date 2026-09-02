import SwiftUI

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
                                            .background(stepManager.dailyGoal == p ? Color.earthGreenFill : Color.earthCard)
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
                                            .background(stepManager.dailyGoal == steps ? Color.earthGreenFill : Color.earthCard)
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
                                    .labelsHidden().tint(.earthGreenFill)
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
                                            Image(wkt: allLocked ? .lock : .lockOpen)
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
                                                Image(wkt: stepManager.lockedWeekdays.contains(wd) ? .lock : .lockOpen)
                                                    .wktIcon(.inline, tint: stepManager.lockedWeekdays.contains(wd) ? .earthGreen : .earthMuted.opacity(0.4),
                                                             filled: stepManager.lockedWeekdays.contains(wd))
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
                                    Image(wkt: showTagCustomizer ? .chevronUp : .chevronDown)
                                        .wktIcon(.inline, tint: .earthMuted.opacity(0.7))
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
                                                                Image(wkt: .check)
                                                                    .wktIcon(.inline, tint: .white, onFill: true)
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
