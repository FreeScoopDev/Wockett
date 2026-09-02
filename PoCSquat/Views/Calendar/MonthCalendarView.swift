import SwiftUI
import Charts

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

    private static let goalDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale     = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func goalFor(_ date: Date) -> Int {
        let cal = Calendar.current
        let wd  = cal.component(.weekday, from: date)
        if date < cal.startOfDay(for: Date()) {
            if let stored = stepManager.historicalDayGoals[Self.goalDateFormatter.string(from: date)] { return stored }
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
        guard let sy = shown.year, let cy = current.year,
              let sm = shown.month, let cm = current.month else { return false }
        return sy > cy || (sy == cy && sm > cm)
    }

    // MARK: - Monthly Stats

    private struct MonthStats {
        let total: Int; let avg: Int; let goalsMet: Int; let daysWithData: Int; let best: Int
        var isEmpty: Bool { daysWithData == 0 }
    }

    private var monthlyStats: MonthStats {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        var total = 0, goalsMet = 0, best = 0, days = 0
        for date in daysInGrid.compactMap({ $0 }) {
            guard cal.startOfDay(for: date) <= today else { continue }
            guard let steps = stepsFor(date), steps > 0 else { continue }
            total += steps; days += 1
            if steps >= goalFor(date) { goalsMet += 1 }
            if steps > best { best = steps }
        }
        return MonthStats(total: total, avg: days > 0 ? total / days : 0,
                          goalsMet: goalsMet, daysWithData: days, best: best)
    }

    // MARK: - Trend Chart Data

    private struct MonthPt: Identifiable {
        let id: Date; let date: Date; let steps: Int; let isGoalMet: Bool
    }

    private var monthTrendPts: [MonthPt] {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        return daysInGrid.compactMap { date -> MonthPt? in
            guard let date, cal.startOfDay(for: date) <= today else { return nil }
            let s = stepsFor(date) ?? 0
            return MonthPt(id: date, date: date, steps: s, isGoalMet: s >= goalFor(date))
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    // Month navigation header
                    HStack {
                        Button {
                            monthShiftDirection = false
                            shiftMonth(-1)
                        } label: {
                            Image(wkt: .chevronLeft).wktIcon(.inline, tint: .earthMuted)
                        }
                        .accessibilityLabel("Previous month")

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
                            Image(wkt: .chevronRight)
                                .wktIcon(.inline, tint: isFutureMonth ? .earthMuted.opacity(0.3) : .earthMuted)
                        }
                        .disabled(isFutureMonth)
                        .accessibilityLabel("Next month")
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
                        VStack(spacing: 0) {
                            // Day grid
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
                                        Color.clear.frame(height: 64)
                                    }
                                }
                            }
                            .padding(.horizontal, 8).padding(.top, 4)

                            // Monthly stats + trend chart
                            let stats = monthlyStats
                            if !stats.isEmpty {
                                monthStatsBar(stats)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 20)

                                monthTrendChart
                                    .padding(.horizontal, 12)
                                    .padding(.top, 12)
                                    .padding(.bottom, 28)
                            }
                        }
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

    // MARK: - Stats Bar

    private func monthStatsBar(_ stats: MonthStats) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            statTile(label: "Total Steps", value: formatK(stats.total), note: "this month")
            statTile(label: "Daily Avg", value: formatK(stats.avg), note: "active days")
            statTile(label: "Goals Met", value: "\(stats.goalsMet)", note: "of \(stats.daysWithData) days")
            statTile(label: "Best Day", value: formatK(stats.best), note: "single day")
        }
    }

    private func statTile(label: String, value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.earthCream)
            Text(label)
                .font(.caption.bold())
                .foregroundColor(.earthCream)
            Text(note)
                .font(.system(size: 10))
                .foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.earthCard)
        .cornerRadius(16)
    }

    // MARK: - Trend Chart

    @ViewBuilder
    private var monthTrendChart: some View {
        let pts = monthTrendPts
        if !pts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Monthly Trend")
                    .font(.caption.bold())
                    .foregroundColor(.earthCream)

                Chart {
                    ForEach(pts) { pt in
                        AreaMark(
                            x: .value("Day", pt.date, unit: .day),
                            y: .value("Steps", pt.steps)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(
                            colors: [Color.earthGreen.opacity(0.22), .clear],
                            startPoint: .top, endPoint: .bottom
                        ))
                        LineMark(
                            x: .value("Day", pt.date, unit: .day),
                            y: .value("Steps", pt.steps)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Color.earthGreen.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    RuleMark(y: .value("Goal", stepManager.currentGoal))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(Color.earthOrange.opacity(0.5))
                        .annotation(position: .trailing, alignment: .center) {
                            Text("Goal")
                                .font(.system(size: 8))
                                .foregroundColor(.earthOrange.opacity(0.7))
                        }
                    if let td = pts.first(where: { Calendar.current.isDateInToday($0.date) }), td.steps > 0 {
                        PointMark(
                            x: .value("Day", td.date, unit: .day),
                            y: .value("Steps", td.steps)
                        )
                        .foregroundStyle(td.isGoalMet ? Color.earthGreen : Color.earthOrange)
                        .symbolSize(44)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisGridLine().foregroundStyle(Color.earthMuted.opacity(0.08))
                        AxisValueLabel(format: .dateTime.day())
                            .font(.system(size: 8))
                            .foregroundStyle(Color.earthMuted)
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(Color.earthMuted.opacity(0.08))
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(formatK(Int(d)))
                                    .font(.system(size: 8))
                                    .foregroundStyle(Color.earthMuted)
                            }
                        }
                    }
                }
                .frame(height: 140)
            }
            .padding(14)
            .background(Color.earthCard)
            .cornerRadius(16)
        }
    }

    // MARK: - Helpers

    private func formatK(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000    { return "\(n / 1_000)K" }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: delta, to: displayMonth) else { return }
        displayMonth = next
        Task { await fetchHKSteps() }
    }
}

// MARK: - Month Day Cell

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
                        Image(wkt: .add)
                            .font(.system(size: 7)).foregroundColor(.earthMuted.opacity(0.3))
                    } else if let met = goalMet {
                        if met {
                            Image(wkt: .check)
                                .font(.system(size: 7, weight: .bold))
                                .foregroundColor(.earthGreen)
                        } else if let s = steps, s > 0 {
                            Text("\(Int(Double(s) / Double(max(1, goal)) * 100))%")
                                .font(.system(size: 6, weight: .bold))
                                .foregroundColor(.orange)
                        } else {
                            Image(wkt: .dismiss)
                                .font(.system(size: 6))
                                .foregroundColor(.earthMuted.opacity(0.4))
                        }
                    }
                }
            }
            .frame(width: 28, height: 28)

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
        .frame(height: 64)
        .background(isToday ? Color.earthCard.opacity(0.6) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
