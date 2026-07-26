import SwiftUI

// MARK: - Weekly Calendar View

struct WeeklyCalendarView: View {
    let days: [CalendarDay]
    let sessions: [WalkSession]
    let weekOffset: Int
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
                            insertion: .move(edge: slideFromLeading ? .leading : .trailing)
                                .combined(with: .opacity),
                            removal: .move(edge: slideFromLeading ? .trailing : .leading)
                                .combined(with: .opacity)
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

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(days) { day in
                        DayCell(day: day) { onDayTap(day) }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 40, coordinateSpace: .local)
                .onEnded { value in
                    guard abs(value.translation.height) < 60 else { return }
                    if value.translation.width < -40 {
                        slideFromLeading = false
                        onWeekChange(1)
                    } else if value.translation.width > 40 {
                        slideFromLeading = true
                        onWeekChange(-1)
                    }
                }
        )
    }
}

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
                        Image(systemName: met ? "checkmark" : "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(met ? .earthGreen : .earthMuted.opacity(0.6))
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
