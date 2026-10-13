import SwiftUI

// MARK: - Settings > Community
//
// Blocked people (synced through your private iCloud, BlockListSync) and
// Delete my community data (CommunityDataDeletion). Audit 2026-10-12,
// finding 15.

/// The two rows Settings shows under Community.
struct CommunitySettingsSection: View {
    var body: some View {
        Section {
            NavigationLink {
                BlockedPeopleView()
            } label: {
                Label { Text("Blocked people") } icon: { Image(wkt: .blockUser).wktIcon(.row, tint: .earthGreen) }
                    .foregroundColor(.earthGreen)
            }
            .accessibilityIdentifier("settings.blockedPeople")
            .listRowBackground(Color.earthCard)

            NavigationLink {
                DeleteCommunityDataView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CommunityDataDeletion.title)
                        Text("Everything you shared in Community. Your walks and pets stay.")
                            .font(.wktLabel).foregroundColor(.earthMuted)
                    }
                } icon: {
                    Image(wkt: .discard).wktIcon(.row, tint: .red)
                }
                .foregroundColor(.earthGreen)
            }
            .accessibilityIdentifier("settings.deleteCommunityData")
            .listRowBackground(Color.earthCard)
        } header: { WktListHeader(title: "Community") }
    }
}

// MARK: - Blocked people

struct BlockedPeopleView: View {
    var store: CommunityModerationStore = .shared

    private struct Row: Identifiable {
        let id: String
        let title: String
    }

    private var rows: [Row] {
        let list = store.blockList
        return list.blockedKeys.map { key in
            Row(id: key, title: list.entries[key]?.label ?? "Someone you blocked")
        }
    }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            List {
                if rows.isEmpty {
                    WktEmptyState(symbol: .blockUser, title: "No one blocked",
                                  message: "People you block in Community show here, on every device signed in to your iCloud.")
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(rows) { row in
                            HStack {
                                Text(row.title).foregroundColor(.earthCream)
                                Spacer()
                                Button("Unblock") { store.unblock(key: row.id) }
                                    .buttonStyle(.borderless)
                                    .foregroundColor(.earthGreen)
                            }
                            .listRowBackground(Color.earthCard)
                        }
                    } footer: {
                        Text("Blocks sync through your private iCloud, so they stay after a reinstall and follow you to your other devices.")
                            .font(.wktLabel).foregroundColor(.earthMuted)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Blocked people")
        .navigationBarTitleDisplayMode(.inline)
        .task { await BlockListSync.shared.sync().value }
    }
}

// MARK: - Delete my community data

@MainActor
@Observable
final class DeleteCommunityDataModel {
    enum Phase: Equatable {
        case idle
        case running(String)
        case done(CommunityDataDeletionReport)
    }

    private(set) var phase: Phase = .idle
    private let runner: CommunityDataDeletionRun

    /// Nil builds the real one here, on the main actor: a default argument
    /// is evaluated outside it.
    init(runner: CommunityDataDeletionRun? = nil) {
        self.runner = runner ?? CommunityDataDeletionRun()
    }

    func start() async {
        if case .running = phase { return }
        phase = .running("Starting…")
        let report = await runner.run { [weak self] kind in self?.phase = .running(kind.progress) }
        phase = .done(report)
    }
}

struct DeleteCommunityDataView: View {
    @State private var model = DeleteCommunityDataModel()
    @State private var confirming = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            List {
                Section {
                    Text(CommunityDataDeletion.explanation)
                        .font(.wktBodyText).foregroundColor(.earthCream)
                        .listRowBackground(Color.earthCard)
                    Text(CommunityDataDeletion.undeletableNote)
                        .font(.wktLabel).foregroundColor(.earthMuted)
                        .listRowBackground(Color.earthCard)
                }

                switch model.phase {
                case .idle:
                    Section {
                        Button(role: .destructive) {
                            confirming = true
                        } label: {
                            Label { Text(CommunityDataDeletion.title) } icon: { Image(wkt: .discard).wktIcon(.row, tint: .red) }
                        }
                        .accessibilityIdentifier("community.deleteAll")
                        .listRowBackground(Color.earthCard)
                    }
                case .running(let text):
                    Section {
                        HStack(spacing: WktSpacing.betweenCards) {
                            ProgressView()
                            Text(text).foregroundColor(.earthCream)
                        }
                        .listRowBackground(Color.earthCard)
                    }
                case .done(let report):
                    resultSection(report)
                }

                Section {
                    Button {
                        if let url = CommunityDataDeletion.supportMailURL(account: reportAccount ?? MyAccount.recordName) { openURL(url) }
                    } label: {
                        Label { Text("Email support@wockett.app") } icon: { Image(wkt: .envelope).wktIcon(.row, tint: .earthGreen) }
                            .foregroundColor(.earthGreen)
                    }
                    .listRowBackground(Color.earthCard)
                } footer: {
                    Text("The email includes your community account ID, so the Wockett team can find what you shared.")
                        .font(.wktLabel).foregroundColor(.earthMuted)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Community data")
        .navigationBarTitleDisplayMode(.inline)
        // The email's account ID comes from here before any run.
        .task { await MyAccount.refresh() }
        .interactiveDismissDisabled(isRunning)
        .navigationBarBackButtonHidden(isRunning)
        .alert(CommunityDataDeletion.confirmTitle, isPresented: $confirming) {
            Button("Delete Everything", role: .destructive) { Task { await model.start() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(CommunityDataDeletion.confirmMessage)
        }
    }

    /// The account the last run found, which a fresh install may not have
    /// saved yet (MyAccount fills in only on the Community screens).
    private var reportAccount: String? {
        if case .done(let report) = model.phase { return report.account }
        return nil
    }

    private var isRunning: Bool {
        if case .running = model.phase { return true }
        return false
    }

    @ViewBuilder
    private func resultSection(_ report: CommunityDataDeletionReport) -> some View {
        Section {
            if let stopped = report.stopped {
                Label { Text(stopped).foregroundColor(.earthCream) } icon: { Image(wkt: .cloudError).wktIcon(.row, tint: .red) }
                    .listRowBackground(Color.earthCard)
            }
            ForEach(report.results, id: \.kind) { result in
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.kind.title).foregroundColor(.earthCream)
                    if !result.summary.isEmpty {
                        Text(result.summary).font(.wktLabel).foregroundColor(.earthMuted)
                    }
                    ForEach(result.failures, id: \.self) { failure in
                        Text(failure).font(.wktLabel).foregroundColor(.red)
                    }
                }
                .listRowBackground(Color.earthCard)
            }
            if report.hasFailures {
                Button("Try Again") { Task { await model.start() } }
                    .foregroundColor(.earthGreen)
                    .listRowBackground(Color.earthCard)
            }
        } header: {
            WktListHeader(title: report.hasFailures ? "Some of it couldn't be deleted" : "Done")
        } footer: {
            if report.hasFailures {
                Text("Try again later, or email us and we'll remove the rest.")
                    .font(.wktLabel).foregroundColor(.earthMuted)
            }
        }
    }
}
