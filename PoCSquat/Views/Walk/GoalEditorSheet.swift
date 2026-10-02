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

    /// "7.5K", "10K", "12.5K". The label used to print 12,500 as "12K".
    nonisolated static func presetLabel(_ steps: Int) -> String {
        steps % 1_000 == 0 ? "\(steps / 1_000)K" : String(format: "%.1fK", Double(steps) / 1_000)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: WktSpacing.betweenSections) {
                        WktSegmentedPicker(selection: $mode, options: [
                            .init(value: 0, title: "Steps", symbol: .steps),
                            .init(value: 1, title: "Distance", symbol: .distance)
                        ])

                        if mode == 0 {
                            Text("Set your daily step goal")
                                .font(.wktBodyText).foregroundColor(.earthMuted)

                            TextField("Steps", text: $goalText)
                                .keyboardType(.numberPad)
                                .font(.wktHeading(48))
                                .multilineTextAlignment(.center)
                                .foregroundColor(.earthCream)

                            WktFlowRow(spacing: 8) {
                                ForEach(stepPresets, id: \.self) { p in
                                    WktChoiceChip(title: Self.presetLabel(p), selected: stepManager.dailyGoal == p) {
                                        goalText = "\(p)"
                                        stepManager.dailyGoal = p
                                    }
                                }
                            }
                        } else {
                            Text("Set your daily distance goal")
                                .font(.wktBodyText).foregroundColor(.earthMuted)

                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                TextField(Self.unitLabel, text: $distText)
                                    .keyboardType(.decimalPad)
                                    .font(.wktHeading(48))
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.earthCream)
                                    .frame(maxWidth: 180)
                                Text(Self.unitLabel)
                                    .font(.wktCardTitle)
                                    .foregroundColor(.earthMuted)
                            }

                            WktFlowRow(spacing: 8) {
                                ForEach(Self.unitPresets, id: \.self) { dist in
                                    let steps = Int(dist * Self.stepsPerUnit)
                                    WktChoiceChip(title: "\(Self.distString(dist)) \(Self.unitLabel)",
                                                  selected: stepManager.dailyGoal == steps) {
                                        distText = Self.distString(dist)
                                        stepManager.dailyGoal = steps
                                    }
                                }
                            }
                        }

                        // ── Custom Weekly Schedule ────────────────────────
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Custom weekly schedule")
                                        .font(.wktRowTitle).foregroundColor(.earthCream)
                                    Text(stepManager.useCustomSchedule
                                         ? "Goals below override your default"
                                         : "Set different goals per day of week")
                                        .font(.wktLabel).foregroundColor(.earthMuted)
                                }
                                Spacer()
                                Toggle("", isOn: $stepManager.useCustomSchedule)
                                    .labelsHidden().tint(.earthGreenFill)
                            }
                            .padding(14)

                            if stepManager.useCustomSchedule {
                                WktDivider()

                                // Lock All / Unlock All header
                                let allLocked = orderedDays.allSatisfy { stepManager.lockedWeekdays.contains($0.0) }
                                HStack {
                                    Text("Tap 🔒 to preserve a day's goal when the default changes")
                                        .font(.wktLabel).foregroundColor(.earthMuted)
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
                                                .accessibilityHidden(true)
                                            Text(allLocked ? "Unlock All" : "Lock All")
                                                .font(.wktLabel)
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
                                                    .font(.wktRowTitle)
                                                if wd == todayWeekday {
                                                    Text("Today").font(.wktLabel).foregroundColor(.earthGreen)
                                                }
                                            }
                                            Spacer()
                                            TextField("steps", value: Binding(
                                                get: { stepManager.weekdayGoals[wd] ?? stepManager.dailyGoal },
                                                set: { stepManager.weekdayGoals[wd] = ($0 == 0) ? nil : $0 }
                                            ), format: .number)
                                            .keyboardType(.numberPad)
                                            .multilineTextAlignment(.trailing)
                                            .font(.wktRowTitle.monospacedDigit())
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
                                            .accessibilityLabel(stepManager.lockedWeekdays.contains(wd) ? "Unlock \(name) goal" : "Lock \(name) goal")
                                            .accessibilityValue(stepManager.lockedWeekdays.contains(wd) ? "Locked" : "Unlocked")
                                            .accessibilityAddTraits(stepManager.lockedWeekdays.contains(wd) ? .isSelected : [])
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
                                                            Text(config.name).font(.wktLabel)
                                                        }
                                                        .padding(.horizontal, 10)
                                                        .frame(minHeight: 30)
                                                        .background(selected ? config.color : Color.earthRaised, in: Capsule())
                                                        .foregroundColor(selected ? .white : config.color)
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
                                        WktDivider().padding(.horizontal, 14)
                                    }
                                }
                            }
                        }
                        .wktCardBackground()
                        .animation(.easeInOut(duration: 0.22), value: stepManager.useCustomSchedule)

                        // ── Customize Tags ───────────────────────────────
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Customize tags")
                                        .font(.wktRowTitle).foregroundColor(.earthCream)
                                    Text("Change emoji and color for each activity")
                                        .font(.wktLabel).foregroundColor(.earthMuted)
                                }
                                Spacer()
                                Button { showTagCustomizer.toggle() } label: {
                                    Image(wkt: showTagCustomizer ? .chevronUp : .chevronDown)
                                        .wktIcon(.inline, tint: .earthMuted.opacity(0.7))
                                }
                                .accessibilityLabel(showTagCustomizer ? "Collapse tag settings" : "Expand tag settings")
                            }
                            .padding(14)

                            if showTagCustomizer {
                                WktDivider()
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
                                            .font(.wktRowTitle)
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
                                                    .accessibilityLabel("Tag color \(i + 1)")
                                                    .accessibilityAddTraits(config.colorIndex == i ? .isSelected : [])
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 14).padding(.vertical, 10)
                                        if config.id != stepManager.tagConfigs.last?.id {
                                            WktDivider().padding(.horizontal, 14)
                                        }
                                    }
                                }
                            }
                        }
                        .wktCardBackground()
                        .animation(.easeInOut(duration: 0.22), value: showTagCustomizer)
                    }
                    .padding(.horizontal, WktSpacing.screen)
                    .padding(.vertical, WktSpacing.betweenSections)
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
