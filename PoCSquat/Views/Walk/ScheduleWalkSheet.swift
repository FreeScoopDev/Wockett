import SwiftUI
import UserNotifications

struct ScheduleWalkSheet: View {
    let routeName: String
    @Environment(\.dismiss) private var dismiss
    @State private var scheduledDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var notifDenied = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(wkt: .calendarAdd)
                        .font(.system(size: 52)).foregroundColor(.earthGreen)
                    Text("Schedule \"\(routeName)\"")
                        .font(.headline).foregroundColor(.earthCream).multilineTextAlignment(.center)
                    DatePicker(
                        "Walk time",
                        selection: $scheduledDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical).tint(.earthGreenFill)
                    .padding(.horizontal)
                    if notifDenied {
                        Label {
                            Text("Enable notifications in iOS Settings to receive reminders")
                        } icon: {
                            Image(wkt: .notificationsOff).wktIcon(.inline, tint: .orange)
                        }
                        .font(.caption).foregroundColor(.orange)
                            .multilineTextAlignment(.center).padding(.horizontal)
                    }
                    Spacer()
                }
                .padding(.top, 24)
            }
            .navigationTitle("Schedule Walk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set Reminder") { Task { await schedule() } }.foregroundColor(.earthGreen)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.earthMuted)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func schedule() async {
        // Same mechanism as Settings' walk reminders: the service prompts for real
        // alerts if delivery is only quiet (the user just asked for something) and
        // keeps one reminder per route, so scheduling again replaces the earlier one.
        let reminder = WalkReminder(title: routeName, routeName: routeName, schedule: .once(scheduledDate))
        guard await NotificationService.shared.addWalkReminder(reminder) else { notifDenied = true; return }
        dismiss()
    }
}
