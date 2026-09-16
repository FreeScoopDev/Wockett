import SwiftUI

// MARK: - TrailRegionsView
//
// Settings → Trail Regions. Lists the CloudKit catalogue against what is on
// the device: the bundled home region, installed downloads, updates, and
// packs this build cannot read. The catalogue is fetched when this screen
// opens, never at launch — a metadata query is cheap but it is still a
// network call the user did not ask for.

struct TrailRegionsView: View {
    private var library: TrailPackLibrary { .shared }

    var body: some View {
        List {
            Section {
                ForEach(library.catalog) { record in
                    RegionRow(record: record)
                        .listRowBackground(Color.earthCard)
                }
                if library.catalog.isEmpty && !library.isRefreshingCatalog {
                    Text(library.catalogError ?? "No regions are published yet.")
                        .font(.caption).foregroundColor(.earthMuted)
                        .listRowBackground(Color.earthCard)
                }
            } header: {
                Text("Regions")
            } footer: {
                Text("Wockett includes North Carolina's named trails. Download a region for every trail in it, or add more regions. Downloads are stored on this device only and are not backed up — they can always be fetched again.")
                    .font(.caption).foregroundColor(.earthMuted)
            }

            if let error = library.catalogError, !library.catalog.isEmpty {
                Section {
                    Label { Text(error) } icon: { Image(wkt: .cloudError).wktIcon(.row, tint: .orange) }
                        .font(.caption).foregroundColor(.earthMuted)
                        .listRowBackground(Color.earthCard)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.earthBg.ignoresSafeArea())
        .navigationTitle("Trail Regions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if library.isRefreshingCatalog {
                    ProgressView()
                } else {
                    Button {
                        Task { await library.refreshCatalog() }
                    } label: {
                        Image(wkt: .refresh).wktIcon(.row, tint: .earthGreen)
                    }
                    .accessibilityLabel("Refresh regions")
                }
            }
        }
        .task { await library.refreshCatalog() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.trailRegions")
    }
}

private struct RegionRow: View {
    let record: TrailRegionRecord
    private var library: TrailPackLibrary { .shared }

    private static let size = ByteCountFormatStyle(style: .file)

    var body: some View {
        let state = library.state(of: record)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.regionName).foregroundColor(.earthCream)
                Text(detail(for: state))
                    .font(.caption).foregroundColor(.earthMuted)
            }
            Spacer()
            action(for: state)
        }
        .padding(.vertical, 2)
    }

    private func detail(for state: TrailPackLibrary.RegionState) -> String {
        let size = record.sizeBytes.formatted(Self.size)
        let count = "\(record.trailCount.formatted()) trails"
        switch state {
        case .bundled: return "Named trails included · full pack \(count), \(size)"
        case .installed: return "Installed · \(count)"
        case .updateAvailable: return "Update available · \(count), \(size)"
        case .available: return "\(count) · \(size)"
        case .needsAppUpdate: return "Needs a newer version of Wockett"
        case .downloading(let p): return p > 0 ? "Downloading \(Int(p * 100))%…" : "Downloading…"
        case .failed(let why): return why
        }
    }

    @ViewBuilder
    private func action(for state: TrailPackLibrary.RegionState) -> some View {
        switch state {
        case .bundled, .available, .failed:
            downloadButton(title: "Download")
        case .updateAvailable:
            downloadButton(title: "Update")
        case .installed:
            Button(role: .destructive) {
                library.remove(region: record.region)
            } label: {
                Image(wkt: .discard).wktIcon(.inline, tint: .red.opacity(0.7))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(record.regionName)")
        case .downloading:
            ProgressView().frame(minWidth: 44, minHeight: 44)
        case .needsAppUpdate:
            Image(wkt: .warning).wktIcon(.inline, tint: .orange)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Needs a newer version of Wockett")
        }
    }

    private func downloadButton(title: String) -> some View {
        Button {
            Task { await library.download(record) }
        } label: {
            Label { Text(title) } icon: { Image(wkt: .cloudDownload).wktIcon(.inline, tint: .earthGreen) }
                .font(.subheadline)
                .foregroundColor(.earthGreen)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(record.regionName)")
    }
}
