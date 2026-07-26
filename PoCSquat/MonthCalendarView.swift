import SwiftUI

// MARK: - Month Calendar View

struct MonthCalendarView: View {
    @ObservedObject var stepManager: StepManager
    let sessions: [WalkSession]
    @Environment(\.dismiss) private var dismiss

    @State private var displayMonth: Date = Calendar.current.startOfDay(for: Date())
    @State private var selectedDay: CalendarDay?
    @State private var monthShiftDirection: Bool = false
    @State private var hkMonthSteps: [Date: Int] = [:]

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()

    private var monthStart: Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: displayMonth))!
    }

    private var daysInGrid: [Date?] {
        let cal          = Calendar.current
        let firstWeekday = cal.component(.weekday, from: monthStart)
        let range        = cal.range(of: .day, in: .month, for: monthStart)!
        var grid: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        for day in range {
            grid.append(cal.date(byAdding: .day, value: day - 1, to: monthStart))
        }
        while grid.count % 7 != 0 { grid.append(nil) }
        return grid
    }

    private func stepsFor(_ date: Date) -> Int? {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return stepManager.todaySteps }
        if date > cal.startOfDay(for: Date()) { return nil }
        if stepManager.trackingMode == .healthKit {
            return hkMonthSteps[cal.startOfDay(for: date)]
        }
        return sessions.filter { cal.isDate($0.date, inSameDayAs: date) }.reduce(0) { $0 + $1.estimatedSteps }
    }

    private func fetchHKSteps() async {
        guard stepManager.trackingMode == .healthKit else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(from: cal.dateComponents([.year, .month], from: monthStart)),
              start < today else { return }
        let end = min(today, cal.date(byAdding: .month, value: 1, to: start) ?? today)
        hkMonthSteps = await stepManager.fetchStepCounts(from: start, to: end)
    }

    private func goalFor(_ date: Date) -> Int {
        let cal = Calendar.current
        let wd  = cal.component(.weekday, from: date)
        if date < cal.startOfDay(for: Date()) {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            if let stored = stepManager.historicalDayGoals[f.string(from: date)] { return stored }
        }
        return (stepManager.useCustomSchedule ? stepManager.weekdayGoals[wd] : nil) ?? stepManager.dailyGoal
    }

    private func calendarDay(for date: Date) -> CalendarDay {
        let cal       = Calendar.current
        let wd        = cal.component(.weekday, from: date)
        let goal      = goalFor(date)
        let steps     = stepsFor(date)
        let tagId     = stepManager.weekdayTags[wd]
        let tagConfig = tagId.flatMap { id in stepManager.tagConfigs.first { $0.id == id } }
        return CalendarDay(
            id: date, date: date, weekday: wd, goal: goal, steps: steps,
            tag: tagId, tagEmoji: tagConfig?.emoji, tagColor: tagConfig?.color
        )
    }

    private var isFutureMonth: Bool {
        let cal     = Calendar.current
        let current = cal.dateComponents([.year, .month], from: Date())
        let shown   = cal.dateComponents([.year, .month], from: monthStart)
        return shown.year! > current.year! || (shown.year! == current.year! && shown.month! > current.month!)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            monthShiftDirection = false
                            shiftMonth(-1)
                        } label: {
                            Image(systemName: "chevron.left").font(.subheadline.bold()).foregroundColor(.earthMuted)
                        }

                        ZStack {
                            Text(Self.monthFmt.string(from: monthStart))
                                .font(.headline).foregroundColor(.earthCream)
                                .id(monthStart)
                                .transition(.asymmetric(
                                    insertion: .move(edge: monthShiftDirection ? .trailing : .leading).combined(with: .opacity),
                                    removal: .move(edge: monthShiftDirection ? .leading : .trailing).combined(with: .opacity)
                                ))
                        }
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .animation(.easeInOut(duration: 0.22), value: monthStart)

                        Button {
                            monthShiftDirection = true
                            shiftMonth(1)
                        } label: {
                            Image(systemName: "chevron.right").font(.subheadline.bold())
                                .foregroundColor(isFutureMonth ? .earthMuted.opacity(0.3) : .earthMuted)
                        }
                        .disabled(isFutureMonth)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)

                    HStack(spacing: 0) {
                        ForEach(["S","M","T","W","T","F","S"], id: \.self) { d in
                            Text(d).font(.caption2.bold()).foregroundColor(.earthMuted)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 4)

                    Divider().background(Color.earthMuted.opacity(0.15)).padding(.horizontal, 8)

                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                            ForEach(daysInGrid.indices, id: \.self) { idx in
                                if let date = daysInGrid[idx] {
                                    MonthDayCell(
                                        date: date,
                                        steps: stepsFor(date),
                                        goal: goalFor(date),
                                        onTap: { selectedDay = calendarDay(for: date) }
                                    )
                                } else {
                                    Color.clear.frame(height: 58)
                                }
                            }
                        }
                        .padding(.horizontal, 8).padding(.top, 4)
                    }
                }
            }
            .navigationTitle("Activity Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.earthGreen)
                }
            }
            .sheet(item: $selectedDay) { day in
                DayDetailSheet(day: day, sessions: sessions)
            }
        }
        .presentationDetents([.large])
        .task { await fetchHKSteps() }
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: delta, to: displayMonth) else { return }
        displayMonth = next
        Task { await fetchHKSteps() }
    }
}

private struct MonthDayCell: View {
    let date: Date
    let steps: Int?
    let goal: Int
    let onTap: () -> Void

    private let cal = Calendar.current
    private var isToday: Bool  { cal.isDateInToday(date) }
    private var isFuture: Bool { date > cal.startOfDay(for: Date()) && !isToday }
    private var progress: Double {
        guard let s = steps else { return 0 }
        return min(1.0, Double(s) / Double(max(1, goal)))
    }
    private var goalMet: Bool? {
        guard let s = steps, !isFuture else { return nil }
        return s >= goal
    }
    private var stepsLabel: String? {
        guard let s = steps else { return nil }
        return s >= 1_000 ? String(format: "%.1fK", Double(s) / 1_000) : "\(s)"
    }

    var body: some View {
        VStack(spacing: 2) {
            Text("\(cal.component(.day, from: date))")
                .font(.system(size: 11, weight: isToday ? .bold : .regular))
                .foregroundColor(isToday ? .earthGreen : isFuture ? .earthMuted.opacity(0.35) : .earthCream)

            ZStack {
                Circle()
                    .stroke(Color.earthMuted.opacity(isFuture ? 0.07 : 0.18), lineWidth: 3)
                if !isFuture, progress > 0 {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(goalMet == true ? Color.earthGreen : Color.earthOrange,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if isToday {
                    Circle().fill(Color.earthGreen.opacity(0.12))
                }
                Group {
                    if isFuture {
                        Image(systemName: "plus")
                            .font(.system(size: 7)).foregroundColor(.earthMuted.opacity(0.3))
                    } else if let met = goalMet {
                        Image(systemName: met ? "checkmark" : "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(met ? .earthGreen : .earthMuted.opacity(0.5))
                    }
                }
            }
            .frame(width: 26, height: 26)

            if let label = stepsLabel {
                Text(label)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(goalMet == true ? .earthGreen : .earthMuted)
            } else if isFuture {
                Text(goal >= 1_000 ? "\(goal / 1_000)K" : "\(goal)")
                    .font(.system(size: 7))
                    .foregroundColor(.earthMuted.opacity(0.3))
            } else {
                Text("—").font(.system(size: 7)).foregroundColor(.earthMuted.opacity(0.25))
            }
        }
        .frame(height: 58)
        .background(isToday ? Color.earthCard.opacity(0.6) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
