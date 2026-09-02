import SwiftUI
import MapKit
import UIKit

// MARK: - Walk History View

struct WalkHistoryView: View {
    @ObservedObject var store: WalkHistoryStore
    @EnvironmentObject var petStore: PetStore
    @Environment(\.dismiss) private var dismiss
    @State private var showManualEntry = false
    @State private var selectedSession: WalkSession?
    @State private var showActiveSessionAlert = false

    private var totalWalks: Int { store.sessions.count }

    private var avgDistanceText: String {
        guard !store.sessions.isEmpty else { return "—" }
        let avg = store.sessions.reduce(0.0) { $0 + $1.totalDistance } / Double(store.sessions.count)
        return MKDistanceFormatter.abbreviated.string(fromDistance: avg)
    }

    private var avgDurationText: String {
        guard !store.sessions.isEmpty else { return "—" }
        let avg = store.sessions.reduce(0.0) { $0 + $1.elapsedTime } / Double(store.sessions.count)
        let mins = Int(avg) / 60
        return mins < 60 ? "\(mins)m" : "\(mins / 60)h \(mins % 60)m"
    }

    private var walksThisWeek: Int {
        let cal = Calendar.current
        guard let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) else { return 0 }
        return store.sessions.filter { $0.date >= weekStart }.count
    }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            Group {
                if store.sessions.isEmpty { emptyState } else { historyList }
            }
        }
        .navigationTitle("Activity History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showManualEntry = true
                } label: {
                    Image(wkt: .add).wktIcon(.inline, tint: .earthGreen)
                }
            }
        }
        .alert("Walk Already Active", isPresented: $showActiveSessionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You have a walk in progress. Return to the home screen to resume or end it first.")
        }
        .sheet(isPresented: $showManualEntry) {
            ManualWalkEntrySheet { session in store.add(session) }
        }
        .sheet(item: $selectedSession) { session in
            WalkSessionDetailSheet(session: session, store: store)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(wkt: .history)
                .font(.system(size: 64)).foregroundColor(.earthMuted.opacity(0.4))
            Text("No Walks Yet")
                .font(.headline).foregroundColor(.earthCream)
            Text("Complete a walk to build your history")
                .font(.subheadline).foregroundColor(.earthMuted).multilineTextAlignment(.center)
            Button("Log a Past Walk") { showManualEntry = true }
                .foregroundColor(.earthGreen).fontWeight(.semibold)
        }.padding()
    }

    private var statsHeader: some View {
        HStack(spacing: 0) {
            statCell("\(totalWalks)", "Total")
            Divider().frame(height: 36)
            statCell(avgDistanceText, "Avg Dist")
            Divider().frame(height: 36)
            statCell(avgDurationText, "Avg Time")
            Divider().frame(height: 36)
            statCell("\(walksThisWeek)", "This Week")
        }
        .padding(.vertical, 12)
        .background(Color.earthCard)
        .cornerRadius(14)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func statCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).foregroundColor(.earthCream)
            Text(label).font(.caption2).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private var historyList: some View {
        List {
            Section {
                statsHeader
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(store.sessions) { session in
                WalkHistoryRow(session: session) {
                    let nav = session.toNavigableRoute()
                    guard ActiveWalkStore.shared.beginSession(route: nav) != nil else {
                        showActiveSessionAlert = true
                        return
                    }
                    dismiss()
                } onInfo: {
                    selectedSession = session
                }
                .listRowBackground(Color.earthCard)
                .listRowSeparatorTint(Color.earthMuted.opacity(0.2))
            }
            .onDelete { store.delete(at: $0) }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
    }
}

// MARK: - Walk Session Detail Sheet

struct WalkSessionDetailSheet: View {
    let session: WalkSession
    @ObservedObject var store: WalkHistoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var notes: String = ""
    @State private var selectedActivityType: String = ""
    @State private var showActivityShare = false

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .short; return f
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        Text(Self.dateFmt.string(from: session.date))
                            .font(.subheadline).foregroundColor(.earthMuted)
                            .padding(.top, 4)

                        HStack(spacing: 12) {
                            detailTile(session.distanceText, "Distance", .distance)
                            detailTile(session.timeText,     "Duration", .time)
                            detailTile("\(session.estimatedSteps.formatted())", "Steps", .walk)
                        }
                        .padding(.horizontal)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Activity Type")
                                .font(.caption.bold()).foregroundColor(.earthMuted)
                                .padding(.horizontal)
                            Picker("Activity Type", selection: $selectedActivityType) {
                                Text("Walk").tag("walking")
                                Text("Run").tag("running")
                                Text("Bike").tag("cycling")
                                Text("Indoor").tag("stationary")
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Notes")
                                .font(.caption.bold()).foregroundColor(.earthMuted)
                                .padding(.horizontal)
                            ZStack(alignment: .topLeading) {
                                if notes.isEmpty {
                                    Text("Add a note about this walk…")
                                        .font(.subheadline).foregroundColor(.earthMuted.opacity(0.5))
                                        .padding(.horizontal, 14).padding(.top, 12)
                                }
                                TextEditor(text: $notes)
                                    .foregroundColor(.earthCream)
                                    .font(.subheadline)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 88)
                                    .padding(.horizontal, 10)
                            }
                            .padding(.vertical, 4)
                            .background(Color.earthCard)
                            .cornerRadius(14)
                            .padding(.horizontal)
                        }

                        Button { showActivityShare = true } label: {
                            Label {
                                Text("Share this Walk")
                            } icon: {
                                Image(wkt: .share).wktIcon(.row, tint: .earthCream)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.earthCard)
                            .foregroundColor(.earthCream)
                            .fontWeight(.semibold)
                            .cornerRadius(14)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.earthGreen.opacity(0.4), lineWidth: 1.5))
                        }
                        .padding(.horizontal)

                        Spacer(minLength: 24)
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(session.routeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        store.updateNotes(id: session.id, notes: notes)
                        store.updateActivityType(id: session.id, activityType: selectedActivityType)
                        dismiss()
                    }
                    .foregroundColor(.earthGreen)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .fontWeight(.semibold).foregroundColor(.earthGreen)
                }
            }
        }
        .sheet(isPresented: $showActivityShare) {
            ActivitySummaryShareSheet(session: session, historyStore: store)
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            notes = session.notes
            selectedActivityType = session.activityType
        }
    }

    private func detailTile(_ value: String, _ label: String, _ icon: WktSymbol) -> some View {
        VStack(spacing: 6) {
            Image(wkt: icon).wktIcon(.row, tint: .earthGreen)
            Text(value).font(.headline.bold()).foregroundColor(.earthCream)
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
        .background(Color.earthCard).cornerRadius(14)
    }
}

// MARK: - Manual Walk Entry Sheet

struct ManualWalkEntrySheet: View {
    let onSave: (WalkSession) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var walkDate = Date()
    @State private var durationHours = 0
    @State private var durationMinutes = 30
    @State private var distanceKm = ""
    @State private var stepCount = ""
    @State private var routeName = ""
    @State private var useSteps = false

    private var distanceMeters: Double? {
        if useSteps, let steps = Double(stepCount), steps > 0 { return steps * 0.762 }
        if !useSteps, let km = Double(distanceKm), km > 0 { return km * 1000 }
        return nil
    }

    private var isValid: Bool {
        let totalMins = durationHours * 60 + durationMinutes
        return totalMins > 0 && distanceMeters != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        sectionCard("When") {
                            DatePicker("Date & Time", selection: $walkDate, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                                .foregroundColor(.earthCream)
                                .tint(.earthGreen)
                        }

                        sectionCard("Duration") {
                            HStack(spacing: 24) {
                                VStack(spacing: 4) {
                                    Text("\(durationHours)").font(.title2.bold()).foregroundColor(.earthCream)
                                    Text("hours").font(.caption).foregroundColor(.earthMuted)
                                    Stepper("", value: $durationHours, in: 0...23).labelsHidden()
                                }
                                VStack(spacing: 4) {
                                    Text("\(durationMinutes)").font(.title2.bold()).foregroundColor(.earthCream)
                                    Text("minutes").font(.caption).foregroundColor(.earthMuted)
                                    Stepper("", value: $durationMinutes, in: 0...59).labelsHidden()
                                }
                                Spacer()
                            }
                        }

                        sectionCard("Distance") {
                            VStack(spacing: 12) {
                                Picker("", selection: $useSteps) {
                                    Text("Kilometres").tag(false)
                                    Text("Steps").tag(true)
                                }
                                .pickerStyle(.segmented)

                                if useSteps {
                                    TextField("Approximate steps", text: $stepCount)
                                        .keyboardType(.numberPad)
                                        .foregroundColor(.earthCream)
                                        .padding(12).background(Color.earthBg).cornerRadius(10)
                                } else {
                                    TextField("Distance in km (e.g. 3.5)", text: $distanceKm)
                                        .keyboardType(.decimalPad)
                                        .foregroundColor(.earthCream)
                                        .padding(12).background(Color.earthBg).cornerRadius(10)
                                }

                                if let meters = distanceMeters {
                                    Text("≈ \(formattedDistance(meters)) · \(Int(meters / 0.762).formatted()) steps")
                                        .font(.caption).foregroundColor(.earthGreen)
                                }
                            }
                        }

                        sectionCard("Notes (optional)") {
                            TextField("Route name or notes…", text: $routeName)
                                .foregroundColor(.earthCream)
                                .padding(12).background(Color.earthBg).cornerRadius(10)
                        }

                        Button(action: save) {
                            Text("Save Walk")
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .background(isValid ? Color.earthGreenFill : Color.earthMuted.opacity(0.3))
                                .foregroundColor(.white).font(.headline).cornerRadius(14)
                        }
                        .disabled(!isValid)
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Log a Past Walk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.earthMuted)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }.fontWeight(.semibold).foregroundColor(.earthGreen)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func formattedDistance(_ meters: Double) -> String {
        MKDistanceFormatter.abbreviated.string(fromDistance: meters)
    }

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.bold()).foregroundColor(.earthMuted).padding(.horizontal)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(14).background(Color.earthCard).cornerRadius(14).padding(.horizontal)
        }
    }

    private func save() {
        guard let meters = distanceMeters else { return }
        let totalSeconds = TimeInterval((durationHours * 60 + durationMinutes) * 60)
        let name = routeName.trimmingCharacters(in: .whitespaces).isEmpty ? "Past Walk" : routeName
        let session = WalkSession(
            id: UUID(),
            routeName: name,
            date: walkDate,
            elapsedTime: totalSeconds,
            totalDistance: meters,
            waypoints: [],
            lapCount: 1,
            isLoop: false
        )
        let count = UserDefaults.standard.integer(forKey: "wkt_manualEntries_count")
        UserDefaults.standard.set(count + 1, forKey: "wkt_manualEntries_count")
        onSave(session)
        dismiss()
    }
}

// MARK: - Walk History Row

struct WalkHistoryRow: View {
    let session: WalkSession
    let onWalkAgain: () -> Void
    let onInfo: () -> Void

    private var rowIcon: WktSymbol {
        switch session.activityType {
        case "running":    return .run
        case "cycling":    return .ride
        case "stationary": return .indoor
        default:           return .walk
        }
    }

    private var rowColor: Color {
        switch session.activityType {
        case "running":    return Color.accentRun
        case "cycling":    return Color.accentRide
        case "stationary": return Color.accentIndoor
        default:           return .earthGreen
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(rowColor.opacity(0.15)).frame(width: 46, height: 46)
                Image(wkt: rowIcon).wktIcon(.row, tint: rowColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(session.routeName).font(.headline).foregroundColor(.earthCream).lineLimit(1)
                Text(session.formattedDate).font(.subheadline).foregroundColor(.earthMuted)
                HStack(spacing: 10) {
                    Label { Text(session.distanceText) } icon: { Image(wkt: .distance).wktIcon(.inline, tint: .earthMuted) }
                    Label { Text(session.timeText) } icon: { Image(wkt: .time).wktIcon(.inline, tint: .earthMuted) }
                }
                .font(.footnote).foregroundColor(.earthMuted)
                if !session.notes.isEmpty {
                    Text(session.notes)
                        .font(.caption).foregroundColor(.earthMuted.opacity(0.8))
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(spacing: 8) {
                Button { onWalkAgain() } label: {
                    Image(wkt: .refresh)
                        .wktIcon(.inline, tint: rowColor)
                        .frame(width: 34, height: 34)
                        .background(rowColor.opacity(0.12))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                Button { onInfo() } label: {
                    Image(wkt: session.notes.isEmpty ? .notePlus : .noteText)
                        .wktIcon(.inline, tint: .earthMuted)
                        .frame(width: 34, height: 34)
                        .background(Color.earthMuted.opacity(0.1))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }
}
