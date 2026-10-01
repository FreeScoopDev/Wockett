import SwiftUI

// MARK: - This week
//
// Seven day bars from `StepManager.weeklyCalendar`, the same window the
// Health tab charts (three days either side of today), so Home and Health
// never disagree about a day. Today is the green bar; days still to come are
// an empty track.

struct HomeWeekCard: View {
    let days: [CalendarDay]

    private let barHeight: CGFloat = 72

    /// The bar scale: the larger of the best day and the highest goal, so a
    /// day that met its goal reaches near the top and a quiet week still
    /// shows small bars rather than every bar at full height.
    private var scale: Double {
        let best = days.compactMap(\.steps).max() ?? 0
        let goal = days.map(\.goal).max() ?? 0
        return Double(max(1, best, goal))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(days) { day in
                column(day)
            }
        }
        .wktCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.weekCard")
    }

    private func column(_ day: CalendarDay) -> some View {
        let fraction = min(1, Double(day.steps ?? 0) / scale)
        return VStack(spacing: 8) {
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.earthTrack)
                    .frame(height: barHeight)
                if !day.isFuture, fraction > 0 {
                    Capsule()
                        .fill(day.isToday ? Color.earthGreen : Color.earthMuted.opacity(0.55))
                        .frame(height: max(8, barHeight * fraction))
                }
            }
            .frame(maxWidth: 22)
            Text(day.date, format: .dateTime.weekday(.narrow))
                .font(.wktLabel)
                .foregroundColor(day.isToday ? .earthGreen : .earthMuted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(day))
    }

    private func accessibilityText(_ day: CalendarDay) -> String {
        let name = day.isToday ? "Today" : day.date.formatted(.dateTime.weekday(.wide))
        guard let steps = day.steps, !day.isFuture else { return "\(name), no steps yet" }
        return "\(name), \(steps.formatted()) steps"
    }
}
