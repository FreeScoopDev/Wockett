import MapKit
import MessageUI
import SwiftUI
import UserNotifications

// MARK: - Walk Complete View

struct WalkCompleteView: View {
    let session: WalkSession
    let activePetNames: [String]
    let petCompletions: [PetCompletion]
    var splits: [(label: String, elapsed: TimeInterval)] = []
    var newPRs: [PRType] = []
    let onDismiss: () -> Void
    var onExcludeFromRouteStats: (() -> Void)? = nil
    @State private var showSchedule        = false
    @State private var excludedFromStats   = false
    @State private var ringProgress: [UUID: Double] = [:]
    @State private var shareItems: [Any]   = []
    @State private var showShareSheet      = false
    @State private var messageRecipient: String? = nil
    @State private var messageBody         = ""
    @State private var showMessageSheet    = false

    private var completionMessage: String {
        switch activePetNames.count {
        case 0: return "Nice work on \(session.routeName). Keep the momentum going!"
        case 1: return "Nice work! \(activePetNames[0]) had a great walk too. 🐾"
        case 2: return "Nice work! \(activePetNames[0]) and \(activePetNames[1]) loved it. 🐾"
        default: return "Nice work! The whole crew crushed it. 🐾"
        }
    }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            ConfettiOverlay()
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 20) {
                    Image(systemName: "figure.walk.circle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(Color.earthGreen)
                        .padding(.bottom, 8)
                    Text("Walk Complete!")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.earthCream)
                    Text(completionMessage)
                        .font(.subheadline)
                        .foregroundColor(.earthMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()
                HStack(spacing: 10) {
                    statTile(value: session.distanceText, label: "Distance", icon: "ruler", color: .earthGreen)
                    statTile(value: session.timeText, label: "Time", icon: "clock", color: .earthOrange)
                    statTile(value: session.estimatedSteps.formatted(), label: "Steps", icon: "figure.walk", color: .earthCream)
                }
                .padding(.horizontal)
                if !newPRs.isEmpty {
                    prBanner
                }
                if !petCompletions.isEmpty {
                    petRingsSection
                }
                if !splits.isEmpty {
                    splitsSection
                }
                if session.customRouteId != nil {
                    routeStatsPrompt
                }
                Spacer()
                VStack(spacing: 12) {
                    Button { showSchedule = true } label: {
                        Label("Schedule This Walk Again", systemImage: "calendar.badge.plus")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18).padding(.horizontal, 20)
                            .background(Color.earthGreen).foregroundColor(.white)
                            .fontWeight(.semibold).cornerRadius(14)
                    }
                    Button { onDismiss() } label: {
                        Text("Done")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18).padding(.horizontal, 20)
                            .background(Color.earthCard)
                            .foregroundColor(.earthCream).cornerRadius(14)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
        }
        .sheet(isPresented: $showSchedule) {
            ScheduleWalkSheet(routeName: session.routeName)
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(activityItems: shareItems)
        }
        .sheet(isPresented: $showMessageSheet) {
            if let phone = messageRecipient {
                MessageComposeSheet(recipients: [phone], body: messageBody)
            }
        }
    }

    private func statTile(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(color).font(.title3)
            Text(value).font(.headline.bold()).foregroundColor(.earthCream)
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20)
        .background(Color.earthCard).cornerRadius(14)
    }

    private var prBanner: some View {
        VStack(spacing: 10) {
            Text("New Personal Record\(newPRs.count > 1 ? "s" : "")! 🏅")
                .font(.caption.bold())
                .foregroundColor(.earthOrange)
            HStack(spacing: 12) {
                ForEach(newPRs) { pr in
                    VStack(spacing: 4) {
                        Text(pr.emoji).font(.title2)
                        Text(pr.title)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.earthCream)
                        Text(pr.valueText)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.earthOrange)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Color.earthOrange.opacity(0.1))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.earthOrange.opacity(0.3), lineWidth: 1))
                }
            }
        }
        .padding(.horizontal)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private var splitsSection: some View {
        VStack(spacing: 8) {
            Text("Splits")
                .font(.caption.bold()).foregroundColor(.earthMuted)
            VStack(spacing: 4) {
                ForEach(splits.indices, id: \.self) { i in
                    HStack {
                        Text(splits[i].label)
                            .font(.caption.bold()).foregroundColor(.earthCream)
                        Spacer()
                        Text(splitTimeText(splits[i].elapsed))
                            .font(.caption).foregroundColor(.earthMuted)
                        if i > 0 {
                            Text("(+\(splitTimeText(splits[i].elapsed - splits[i-1].elapsed)))")
                                .font(.caption2).foregroundColor(.earthMuted.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Color.earthCard).cornerRadius(8)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private var routeStatsPrompt: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if excludedFromStats {
                    Text("Excluded from route history")
                        .font(.subheadline.bold()).foregroundColor(.earthMuted)
                } else {
                    Text("Counting toward \"\(session.routeName)\"")
                        .font(.subheadline.bold()).foregroundColor(.earthCream)
                }
                Text(excludedFromStats ? "This session won't appear in route runs" : "Tap exclude to skip route stats for this session")
                    .font(.caption).foregroundColor(.earthMuted)
            }
            Spacer()
            if !excludedFromStats {
                Button("Exclude") {
                    excludedFromStats = true
                    onExcludeFromRouteStats?()
                }
                .font(.caption.bold())
                .foregroundColor(.earthMuted)
            }
        }
        .padding(14)
        .background(Color.earthCard)
        .cornerRadius(12)
        .padding(.horizontal)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: excludedFromStats)
    }

    private func splitTimeText(_ t: TimeInterval) -> String {
        let s = Int(t); let m = s / 60
        return m < 60 ? "\(m)m \(s % 60)s" : "\(m / 60)h \(m % 60)m"
    }

    private var petRingsSection: some View {
        VStack(spacing: 12) {
            Text("Your crew's progress today")
                .font(.caption.bold()).foregroundColor(.earthMuted)
            HStack(spacing: 24) {
                ForEach(petCompletions, id: \.pet.id) { completion in
                    petRingView(completion: completion)
                }
            }
        }
        .padding(.vertical, 16)
        .onAppear {
            for (i, completion) in petCompletions.enumerated() {
                withAnimation(.spring(duration: 0.9, bounce: 0.25).delay(Double(i) * 0.18)) {
                    ringProgress[completion.pet.id] = completion.progress
                }
            }
        }
    }

    private func petRingView(completion: PetCompletion) -> some View {
        let progress = ringProgress[completion.pet.id] ?? 0
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(completion.pet.accentColor.opacity(0.2), lineWidth: 7)
                    .frame(width: 72, height: 72)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(completion.pet.accentColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .frame(width: 72, height: 72)
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(completion.pet.displayEmoji)
                        .font(.system(size: 26))
                        .scaleEffect(progress > 0 ? 1.0 : 0.6)
                        .animation(.spring(duration: 0.5, bounce: 0.4).delay(0.3), value: progress)
                    Text("\(Int(completion.progress * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.earthMuted)
                }
            }
            Text(completion.pet.name)
                .font(.caption2.bold())
                .foregroundColor(.earthMuted)

            HStack(spacing: 6) {
                Button {
                    shareCard(for: completion)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(completion.pet.accentColor)
                }
                if completion.pet.ownerPhone != nil {
                    Button {
                        messageOwner(for: completion)
                    } label: {
                        Label("Message", systemImage: "message.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.earthGreen)
                    }
                }
            }
        }
    }

    @MainActor
    private func shareCard(for completion: PetCompletion) {
        let petMeters = session.petDistances[completion.pet.id] ?? 0
        let card = PetWalkSummaryCard(
            pet: completion.pet,
            sessionDistance: petMeters,
            sessionDuration: session.elapsedTime,
            goalProgress: completion.progress,
            date: session.date
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3.0
        guard let image = renderer.uiImage else { return }
        shareItems = [image]
        showShareSheet = true
    }

    private func messageOwner(for completion: PetCompletion) {
        guard MFMessageComposeViewController.canSendText() else { return }
        let petMeters = session.petDistances[completion.pet.id] ?? 0
        let dist = MKDistanceFormatter.abbreviated.string(fromDistance: petMeters)
        let steps = Int(petMeters / 0.762).formatted()
        let ownerFirst = completion.pet.ownerName?.components(separatedBy: " ").first ?? "there"
        messageBody = "Hi \(ownerFirst)! Just finished walking \(completion.pet.name) 🐾\n\n📏 \(dist)  👟 \(steps) steps  ⏱ \(session.timeText)\n\nSent from Wockett"
        messageRecipient = completion.pet.ownerPhone
        showMessageSheet = true
    }
}

// MARK: - Schedule Walk Sheet

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
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 52)).foregroundColor(.earthGreen)
                    Text("Schedule \"\(routeName)\"")
                        .font(.headline).foregroundColor(.earthCream).multilineTextAlignment(.center)
                    DatePicker(
                        "Walk time",
                        selection: $scheduledDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical).tint(.earthGreen)
                    .padding(.horizontal)
                    if notifDenied {
                        Label("Enable notifications in iOS Settings to receive reminders", systemImage: "bell.slash")
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
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if !granted { notifDenied = true; return }
        } else if status == .denied {
            notifDenied = true; return
        }
        let content = UNMutableNotificationContent()
        content.title = "Time for your walk!"
        content.body = "Your \(routeName) walk is scheduled — lace up!"
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: scheduledDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
        dismiss()
    }
}

// MARK: - Pet Walk Summary Card

struct PetWalkSummaryCard: View {
    let pet: PetProfile
    let sessionDistance: Double
    let sessionDuration: TimeInterval
    let goalProgress: Double
    let date: Date

    private var steps: Int { Int(sessionDistance / 0.762) }
    private var distText: String { MKDistanceFormatter.abbreviated.string(fromDistance: sessionDistance) }
    private var timeText: String {
        let m = Int(sessionDuration) / 60
        return m < 60 ? "\(m) min" : "\(m / 60)h \(m % 60)m"
    }
    private var dateText: String {
        let f = DateFormatter(); f.dateStyle = .medium
        return f.string(from: date)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.13, green: 0.12, blue: 0.11)

            LinearGradient(
                colors: [pet.accentColor.opacity(0.35), .clear],
                startPoint: .topLeading, endPoint: .center
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(pet.accentColor.opacity(0.25))
                            .frame(width: 58, height: 58)
                        Text(pet.displayEmoji).font(.system(size: 30))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(pet.name)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        if let breed = pet.breed {
                            Text(breed)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.55))
                        }
                    }

                    Spacer()

                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.15), lineWidth: 4)
                            .frame(width: 46, height: 46)
                        Circle()
                            .trim(from: 0, to: min(1, goalProgress))
                            .stroke(pet.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 46, height: 46)
                            .rotationEffect(.degrees(-90))
                        Text("\(Int(min(1, goalProgress) * 100))%")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                }

                Rectangle()
                    .fill(.white.opacity(0.1))
                    .frame(height: 1)

                HStack(spacing: 0) {
                    statCol(value: distText,             label: "Distance")
                    Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 32)
                    statCol(value: steps.formatted(),    label: "Steps")
                    Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 32)
                    statCol(value: timeText,             label: "Duration")
                }

                HStack {
                    Text(dateText)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                    Spacer()
                    HStack(spacing: 3) {
                        Text("Wockett")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(pet.accentColor.opacity(0.85))
                        Text("🐾").font(.system(size: 10))
                    }
                }
            }
            .padding(18)
        }
        .frame(width: 360, height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func statCol(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Share Helpers

struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct MessageComposeSheet: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = recipients
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            dismiss()
        }
    }
}
