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
        case 0:  return "This week"
        case -1: return "Last week"
        case 1:  return "Next week"
        case let n where n < 0: return "\(-n) weeks ago"
        default: return "In \(weekOffset) weeks"
        }
    }

    // A `WktSection` in shape: the week's name as the heading, with the week
    // controls where its link would be, and one card under it holding the
    // seven days and the 30-day trend, like Home's "This week" card.
    var body: some View {
        VStack(alignment: .leading, spacing: WktSpacing.betweenCards) {
            HStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    Text(weekLabel)
                        .font(.wktSection)
                        .foregroundColor(.earthCream)
                        .accessibilityAddTraits(.isHeader)
                        .id(weekOffset)
                        .transition(.asymmetric(
                            insertion: .move(edge: slideFromLeading ? .leading : .trailing).combined(with: .opacity),
                            removal:   .move(edge: slideFromLeading ? .trailing : .leading).combined(with: .opacity)
                        ))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .animation(.easeInOut(duration: 0.22), value: weekOffset)

                WktRoundIconButton(symbol: .chevronLeft, label: "Previous week", disabled: weekOffset <= -52) {
                    slideFromLeading = true
                    onWeekChange(-1)
                }
                WktRoundIconButton(symbol: .calendar, label: "Open month calendar", action: onCalendarTap)
                WktRoundIconButton(symbol: .chevronRight, label: "Next week", disabled: weekOffset >= 52) {
                    slideFromLeading = false
                    onWeekChange(1)
                }
            }

            VStack(alignment: .leading, spacing: WktSpacing.cardPadding) {
                HStack(spacing: 4) {
                    ForEach(days) { day in
                        DayCell(day: day) { onDayTap(day) }
                    }
                }
                WktDivider()
                TrendChartSection(stepManager: stepManager)
            }
            .wktCard(padding: 12)
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
                Text("Last 30 days")
                    .font(.wktLabel)
                    .foregroundColor(.earthMuted)
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
            .padding(.horizontal, 4)

            // Chart
            if points.isEmpty {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.earthTrack.opacity(0.5))
                    .frame(height: 72)
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
                        .annotation(position: .top, alignment: .leading) {
                            Text("Goal")
                                .font(.wktBody(9))
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
                        AxisGridLine().foregroundStyle(Color.earthTrack)
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(.wktBody(9))
                            .foregroundStyle(Color.earthMuted)
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(Color.earthTrack)
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(formatK(Int(d)))
                                    .font(.wktBody(9))
                                    .foregroundStyle(Color.earthMuted)
                            }
                        }
                    }
                }
                .frame(height: 80)
                .padding(.horizontal, 4)
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
        let start = cal.date(byAdding: .day, value: -29, to: today) ?? today
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
                .font(.wktLabel)
                .foregroundColor(.earthCream)
            Text(label)
                .font(.wktLabel)
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

    private static let numFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d"; return f
    }()

    // Seven of these share the card's width (about 42 pt each), so the
    // day number and step count use the label size and the tag the one
    // smaller size the calendar needs.
    var body: some View {
        VStack(spacing: 6) {
            Text(day.date, format: .dateTime.weekday(.abbreviated))
                .font(.wktLabel)
                .foregroundColor(day.isToday ? .earthGreen : .earthMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(Self.numFmt.string(from: day.date))
                .font(.wktRowTitle)
                .foregroundColor(day.isToday ? .earthCream : .earthMuted)

            ZStack {
                Circle()
                    .stroke(Color.earthTrack.opacity(day.isFuture ? 0.5 : 1), lineWidth: 4)

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
                        Image(wkt: .subtract)
                            .font(.system(size: 9)).foregroundColor(.earthMuted.opacity(0.4))
                    } else if day.isToday {
                        Image(wkt: .walk)
                            .font(.system(size: 11)).foregroundColor(.earthGreen)
                    } else if let met = day.goalMet {
                        if met {
                            Image(wkt: .check)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.earthGreen)
                        } else if let steps = day.steps, steps > 0 {
                            Text(WktPercent.text(Double(steps) / Double(max(1, day.goal))))
                                .font(.wktBody(9))
                                .foregroundColor(.earthOrange)
                                .minimumScaleFactor(0.7)
                        } else {
                            Image(wkt: .dismiss)
                                .font(.system(size: 9))
                                .foregroundColor(.earthMuted.opacity(0.5))
                        }
                    }
                }
            }
            .frame(width: 34, height: 34)

            if let emoji = day.tagEmoji, let color = day.tagColor {
                Text(emoji)
                    .font(.system(size: 10))
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(color.opacity(0.18), in: Capsule())
                    .frame(height: 15)
            } else if let tag = day.tag {
                Text(tag)
                    .font(.wktBody(9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.earthRaised, in: Capsule())
                    .foregroundColor(.earthMuted)
                    .frame(height: 15)
            } else {
                Color.clear.frame(height: 15)
            }

            if let steps = day.steps {
                Text(steps >= 1_000 ? "\(steps / 1_000)K" : "\(steps)")
                    .font(.wktLabel)
                    .foregroundColor(day.goalMet == true ? .earthGreen : .earthMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("—").font(.wktLabel).foregroundColor(.earthMuted.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(day.isToday ? Color.earthRaised : Color.clear,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        let name = day.isToday ? "Today" : day.date.formatted(.dateTime.weekday(.wide).month().day())
        guard !day.isFuture, let steps = day.steps else { return name }
        return "\(name), \(steps.formatted()) of \(day.goal.formatted()) steps"
    }
}
