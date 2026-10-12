import SwiftUI
import MapKit

struct DayDetailSheet: View {
    let day: CalendarDay
    let sessions: [WalkSession]
    @Environment(\.dismiss) private var dismiss
    @State private var showReminderError = false
    @State private var isAddingReminder = false
    private var notifications = NotificationService.shared

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
                    VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                        WktGoalRing(progress: day.isFuture ? 0 : day.progress, lineWidth: 14) {
                            VStack(spacing: 4) {
                                if let steps = day.steps {
                                    Text(steps.formatted())
                                        .font(.wktMetric)
                                        .foregroundColor(.earthCream)
                                        .minimumScaleFactor(0.6)
                                    Text("of \(day.goal.formatted())")
                                        .font(.wktLabel).foregroundColor(.earthMuted)
                                } else if day.isFuture {
                                    Text(day.goal.formatted())
                                        .font(.wktCardTitle)
                                        .foregroundColor(.earthMuted)
                                    Text("planned")
                                        .font(.wktLabel).foregroundColor(.earthMuted)
                                } else {
                                    Text("—")
                                        .font(.wktMetric)
                                        .foregroundColor(.earthMuted)
                                    Text("no data")
                                        .font(.wktLabel).foregroundColor(.earthMuted)
                                }
                            }
                        }
                        .frame(width: 180, height: 180)
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)

                        // Tag + accomplishment chips
                        HStack(spacing: 8) {
                            if let emoji = day.tagEmoji, let color = day.tagColor, let tag = day.tag {
                                WktStatusChip(text: tag, textColor: color) {
                                    Text(emoji).font(.wktLabel) // the tag's own emoji (data)
                                }
                            }
                            if day.isFuture {
                                WktStatusChip(text: "Scheduled", textColor: .earthMuted) {
                                    Image(wkt: .calendarClock).wktIcon(.inline, tint: .earthMuted)
                                }
                            } else if let met = day.goalMet {
                                WktStatusChip(text: met ? "Goal achieved" : "Goal not met",
                                              textColor: met ? .earthGreen : .earthMuted) {
                                    Image(wkt: met ? .success : .close)
                                        .wktIcon(.inline, tint: met ? .earthGreen : .earthMuted, filled: met)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)

                        // Stats row — always show goal; add steps/progress for non-future days
                        HStack(spacing: 0) {
                            statCell(label: "Goal", value: day.goal.formatted())
                            if let steps = day.steps {
                                columnDivider
                                statCell(label: "Steps", value: steps.formatted())
                                columnDivider
                                statCell(label: "Progress", value: WktPercent.text(day.progress))
                                columnDivider
                                statCell(label: "Distance", value: Self.formatDist(Double(steps) * 0.762))
                            }
                        }
                        .wktCard(padding: 14)

                        // Reminder button for future days
                        if day.isFuture {
                            Button {
                                Task { await scheduleReminder() }
                            } label: {
                                if reminderScheduled {
                                    WktSecondaryLabel(title: "Reminder set for \(reminderTime)", symbol: .success)
                                } else {
                                    WktPrimaryLabel(title: "Remind me at \(reminderTime)", symbol: .notifications)
                                }
                            }
                            .buttonStyle(BounceButtonStyle(scale: 0.98))
                            .disabled(reminderScheduled || isAddingReminder)
                            .alert("Couldn't Add Reminder", isPresented: $showReminderError) {
                                Button("OK", role: .cancel) {}
                            } message: {
                                Text("Notifications are off for Wockett. Turn them on in the Settings app to get walk reminders.")
                            }
                        }

                        // Walk sessions
                        if !daySessions.isEmpty {
                            WktSection(title: "Walks") {
                                VStack(spacing: 0) {
                                    ForEach(Array(daySessions.enumerated()), id: \.element.id) { index, session in
                                        if index > 0 { WktDivider() }
                                        sessionRow(session)
                                    }
                                }
                                .wktCard(padding: 14)
                            }
                        } else if !day.isFuture {
                            Text("No walks recorded this day")
                                .font(.wktBodyText).foregroundColor(.earthMuted)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, WktSpacing.screen)
                    .padding(.vertical, WktSpacing.betweenSections)
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

    /// Derived from the saved reminders, so reopening the day still shows it
    /// as set, and it cannot be added twice.
    private var reminderScheduled: Bool {
        WalkReminder.hasGoalDayReminder(on: day.date, in: notifications.walkReminders)
    }

    private var reminderTime: String {
        WalkReminder.goalDayMorning(of: day.date).formatted(date: .omitted, time: .shortened)
    }

    /// A walk reminder like Settings' and a route's: a notification, listed
    /// and deletable in Settings. The service shows the real notification
    /// prompt if delivery is only quiet, because the user just asked.
    private func scheduleReminder() async {
        // A second tap while the first is still waiting on the service must
        // not add a second reminder.
        guard !isAddingReminder, !reminderScheduled else { return }
        isAddingReminder = true
        defer { isAddingReminder = false }
        let reminder = WalkReminder.goalDay(day.date, goal: day.goal)
        guard await notifications.addWalkReminder(reminder) else { showReminderError = true; return }
    }

    private static func formatDist(_ meters: Double) -> String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: meters)
    }

    private var columnDivider: some View {
        Rectangle().fill(Color.earthTrack).frame(width: 1, height: 40)
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.wktRowTitle.monospacedDigit())
                .foregroundColor(.earthCream)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.wktLabel).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func sessionRow(_ session: WalkSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.routeName)
                    .font(.wktRowTitle).foregroundColor(.earthCream)
                HStack(spacing: 12) {
                    Label { Text(session.distanceText) } icon: { Image(wkt: .distance).wktIcon(.inline, tint: .earthMuted) }
                    Label { Text(session.timeText) } icon: { Image(wkt: .time).wktIcon(.inline, tint: .earthMuted) }
                }
                .font(.wktLabel).foregroundColor(.earthMuted)
            }
            Spacer()
            Text("\(session.estimatedSteps.formatted()) steps")
                .font(.wktLabel).foregroundColor(.earthGreen)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
