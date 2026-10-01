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
                    WktIconBadge(symbol: .calendarAdd, size: 64)
                    Text("Schedule \"\(routeName)\"")
                        .font(.wktCardTitle).foregroundColor(.earthCream).multilineTextAlignment(.center)
                    DatePicker(
                        "Walk time",
                        selection: $scheduledDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical).tint(.earthGreenFill)
                    .wktCard(padding: 8)
                    if notifDenied {
                        Label {
                            Text("Enable notifications in iOS Settings to receive reminders")
                        } icon: {
                            Image(wkt: .notificationsOff).wktIcon(.inline, tint: .earthOrange)
                        }
                        .font(.wktLabel).foregroundColor(.earthOrange)
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                }
                .padding(.horizontal, WktSpacing.screen)
                .padding(.top, 24)
            }
            .navigationTitle("Schedule Walk")
            .navigationBarTitleDisplayMode(.inline)
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
