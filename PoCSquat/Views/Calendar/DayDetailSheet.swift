import SwiftUI
import MapKit
import EventKit

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
                                .background(reminderScheduled ? Color.earthCard : Color.earthGreenFill)
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
