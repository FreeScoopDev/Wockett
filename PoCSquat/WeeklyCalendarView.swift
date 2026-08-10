import SwiftUI
import Charts

// MARK: - Weekly Calendar View

struct WeeklyCalendarView: View {
    let days: [CalendarDay]
    let weekOffset: Int
    let stepManager: StepManager
    let onDayTap: (CalendarDay) -> Void
    let onWeekChange: (Int) -> Void
    let onCalendarTap: () -> Void

    @State private var slideFromLeading = false

    private var weekLabel: String {
        switch weekOffset {
        case 0:  return "This Week"
        case -1: return "Last Week"
        case 1:  return "Next Week"
        case let n where n < 0: return "\(-n) Weeks Ago"
        default: return "In \(weekOffset) Weeks"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Week navigation header
            HStack(spacing: 8) {
                Button {
                    slideFromLeading = true
                    onWeekChange(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption.bold())
                        .foregroundColor(weekOffset <= -52 ? .earthMuted.opacity(0.25) : .earthMuted)
                }
                .disabled(weekOffset <= -52)

                ZStack {
                    Text(weekLabel)
                        .font(weekOffset == 0 ? .subheadline.bold() : .caption.bold())
                        .foregroundColor(weekOffset == 0 ? .earthCream : .earthMuted)
                        .id(weekOffset)
                        .transition(.asymmetric(
                            insertion: .move(edge: slideFromLeading ? .leading : .trailing).combined(with: .opacity),
                            removal:   .move(edge: slideFromLeading ? .trailing : .leading).combined(with: .opacity)
                        ))
                }
                .frame(maxWidth: .infinity)
                .clipped()
                .animation(.easeInOut(duration: 0.22), value: weekOffset)

                Button { onCalendarTap() } label: {
                    Image(systemName: "calendar")
                        .font(.caption.bold()).foregroundColor(.earthMuted)
                }

                Button {
                    slideFromLeading = false
                    onWeekChange(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundColor(weekOffset >= 52 ? .earthMuted.opacity(0.25) : .earthMuted)
                }
                .disabled(weekOffset >= 52)
            }
            .padding(.horizontal, 20)

            // 7-day cells
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(days) { day in
                        DayCell(day: day) { onDayTap(day) }
                    }
                }
                .padding(.horizontal, 16)
            }

            // 30-day trend chart
            Divider()
                .background(Color.earthMuted.opacity(0.1))
                .padding(.horizontal, 20)
                .padding(.top, 4)

            TrendChartSection(stepManager: stepManager)
                .padding(.top, 2)
        }
        .gesture(
            DragGesture(minimumDistance: 40, coordinateSpace: .local)
                .onEnded { value in
                    guard abs(value.translation.height) < 60 else { return }
                    if value.translation.width < -40 {
                        slideFromLeading = false; onWeekChange(1)
                    } else if value.translation.width > 40 {
                        slideFromLeading = true; onWeekChange(-1)
                    }
                }
        )
    }
}

// MARK: - 30-Day Trend Chart

private struct TrendChartSection: View {
    let stepManager: StepManager

    private struct DayPt: Identifiable {
        let id: Date; let date: Date; let steps: Int; let isGoalMet: Bool
    }

    @State private var points: [DayPt] = []

    private var nonZero: [DayPt] { points.filter { $0.steps > 0 } }
    private var avg: Int? {
        nonZero.isEmpty ? nil : nonZero.map(\.steps).reduce(0,+) / nonZero.count
    }
    private var metCount: Int { nonZero.filter(\.isGoalMet).count }
    private var bestDay: Int? { nonZero.map(\.steps).max() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack(alignment: .firstTextBaseline) {
                Text("Last 30 Days")
                    .font(.caption.bold())
                    .foregroundColor(.earthCream)
                Spacer()
                HStack(spacing: 12) {
                    if let a = avg {
                        miniStat(label: "Avg", value: formatK(a))
                    }
                    miniStat(label: "Goals", value: "\(metCount)/\(nonZero.count)")
                    if let b = bestDay {
                        miniStat(label: "Best", value: formatK(b))
                    }
                }
            }
            .padding(.horizontal, 20)

            // Chart
            if points.isEmpty {
                Color.earthMuted.opacity(0.06)
                    .frame(height: 72)
                    .cornerRadius(8)
                    .padding(.horizontal, 20)
            } else {
                Chart {
                    ForEach(points) { pt in
                        AreaMark(
                            x: .value("Day", pt.date, unit: .day),
                            y: .value("Steps", pt.steps)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(
                            colors: [Color.earthGreen.opacity(0.20), .clear],
                            startPoint: .top, endPoint: .bottom
                        ))
                        LineMark(
                            x: .value("Day", pt.date, unit: .day),
                            y: .value("Steps", pt.steps)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Color.earthGreen.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                    }
                    RuleMark(y: .value("Goal", stepManager.currentGoal))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(Color.earthOrange.opacity(0.5))
                        .annotation(position: .trailing, alignment: .center) {
                            Text("Goal")
                                .font(.system(size: 8))
                                .foregroundColor(.earthOrange.opacity(0.7))
                        }
                    // Today's dot
                    if let td = points.first(where: { Calendar.current.isDateInToday($0.date) }),
                       td.steps > 0 {
                        PointMark(
                            x: .value("Day", td.date, unit: .day),
                            y: .value("Steps", td.steps)
                        )
                        .foregroundStyle(td.isGoalMet ? Color.earthGreen : Color.earthOrange)
                        .symbolSize(32)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisGridLine().foregroundStyle(Color.earthMuted.opacity(0.08))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
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
                .frame(height: 80)
                .padding(.horizontal, 20)
            }
        }
        .task { await load() }
        .onChange(of: stepManager.todaySteps) { _, _ in
            Task { await load() }
        }
    }

    private func load() async {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -29, to: today)!
        let counts = await stepManager.fetchStepCounts(from: start, to: Date())
        let goal   = stepManager.currentGoal

        points = (0..<30).compactMap { i in
            guard let date = cal.date(byAdding: .day, value: i, to: start) else { return nil }
            let day   = cal.startOfDay(for: date)
            let steps = cal.isDateInToday(day)
                ? stepManager.todaySteps
                : (counts[day] ?? 0)
            return DayPt(id: day, date: day, steps: steps, isGoalMet: steps >= goal)
        }
    }

    private func miniStat(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.earthCream)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.earthMuted)
        }
    }

    private func formatK(_ n: Int) -> String {
        if n >= 10_000 { return "\(n / 1_000)K" }
        if n >= 1_000  { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Day Cell

private struct DayCell: View {
    let day: CalendarDay
    let onTap: () -> Void

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
    private static let numFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d"; return f
    }()

    var body: some View {
        VStack(spacing: 5) {
            Text(Self.dayFmt.string(from: day.date).uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(day.isToday ? .earthGreen : .earthMuted)

            Text(Self.numFmt.string(from: day.date))
                .font(.caption.bold())
                .foregroundColor(day.isToday ? .earthCream : .earthMuted)

            ZStack {
                Circle()
                    .stroke(Color.earthMuted.opacity(day.isFuture ? 0.08 : 0.18), lineWidth: 4)

                if !day.isFuture, let steps = day.steps {
                    let prog = min(1.0, Double(steps) / Double(max(1, day.goal)))
                    Circle()
                        .trim(from: 0, to: prog)
                        .stroke(
                            day.goalMet == true ? Color.earthGreen : Color.earthOrange,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }

                Group {
                    if day.isFuture {
                        Image(systemName: "minus")
                            .font(.system(size: 9)).foregroundColor(.earthMuted.opacity(0.3))
                    } else if day.isToday {
                        Image(systemName: "figure.walk")
                            .font(.system(size: 10)).foregroundColor(.earthGreen)
                    } else if let met = day.goalMet {
                        if met {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.earthGreen)
                        } else if let steps = day.steps, steps > 0 {
                            Text("\(Int(Double(steps) / Double(max(1, day.goal)) * 100))%")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.orange)
                        } else {
                            Image(systemName: "xmark")
                                .font(.system(size: 8))
                                .foregroundColor(.earthMuted.opacity(0.4))
                        }
                    }
                }
            }
            .frame(width: 38, height: 38)

            if let emoji = day.tagEmoji, let color = day.tagColor {
                Text(emoji)
                    .font(.system(size: 10))
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(color.opacity(0.18))
                    .cornerRadius(4)
                    .frame(height: 15)
            } else if day.tag != nil {
                Text(day.tag!)
                    .font(.system(size: 7, weight: .bold))
                    .lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.earthCard)
                    .foregroundColor(.earthMuted)
                    .cornerRadius(5)
                    .frame(height: 15)
            } else {
                Color.clear.frame(height: 15)
            }

            if let steps = day.steps {
                Text(steps >= 1_000 ? "\(steps / 1_000)K" : "\(steps)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(day.goalMet == true ? .earthGreen : .earthMuted)
            } else {
                Text("—").font(.system(size: 9)).foregroundColor(.earthMuted.opacity(0.3))
            }
        }
        .frame(width: 50)
        .padding(.vertical, 10)
        .background(day.isToday ? Color.earthCard : Color.clear)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(day.isToday ? Color.earthGreen.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .onTapGesture { onTap() }
    }
}
