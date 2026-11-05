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
            let groups = TrailPackLibrary.ordered(library.catalog, isOnPhone: library.isOnPhone)
            regionSection("On this phone", groups.onPhone)
            regionSection("Available", groups.available)
            Section {
                if library.catalog.isEmpty && !library.isRefreshingCatalog {
                    Text(library.catalogError ?? "No regions are published yet.")
                        .font(.wktLabel).foregroundColor(.earthMuted)
                        .listRowBackground(Color.earthCard)
                }
            } footer: {
                Text(Self.footer).font(.wktLabel).foregroundColor(.earthMuted)
            }

            if let error = library.catalogError, !library.catalog.isEmpty {
                Section {
                    Label { Text(error) } icon: { Image(wkt: .cloudError).wktIcon(.row, tint: .earthOrange) }
                        .font(.wktLabel).foregroundColor(.earthMuted)
                        .listRowBackground(Color.earthCard)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .font(.wktRowTitle)
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

    static let footer = "North Carolina's named trails come with Wockett. Download a state for all of its trails, unnamed paths included. Downloaded regions keep trail lines and details on this phone, so the Trails list and trail pages work without a signal. They don't include map tiles. The map, directions and weather still need a connection, or an offline map saved in Apple Maps. Downloads aren't backed up; you can always download them again."

    @ViewBuilder
    private func regionSection(_ title: String, _ records: [TrailRegionRecord]) -> some View {
        if !records.isEmpty {
            Section {
                ForEach(records) { record in
                    RegionRow(record: record).listRowBackground(Color.earthCard)
                }
            } header: {
                WktListHeader(title: title)
            }
        }
    }
}

/// The regions screen as a sheet, for the entries outside Settings.
struct TrailRegionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TrailRegionsView().toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct RegionRow: View {
    let record: TrailRegionRecord
    private var library: TrailPackLibrary { .shared }

    /// The open pack's own date, local: no fetch.
    private var dataDate: Date? { library.packInfos.first { $0.region == record.region }?.builtAt }

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let state = library.state(of: record)
        // At the accessibility sizes the button goes under the name: beside
        // it, both broke mid-word at Accessibility 2 ("Connectic / ut",
        // "Downl / oad"; spec fix/large-text-round2, item 2).
        let stacks = WktNameLayout.stacks(typeSize)
        let row = stacks
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.regionName).foregroundColor(.earthCream)
                Text(TrailRegionText.detail(state: state, record: record, dataDate: dataDate))
                    .font(.wktLabel).foregroundColor(.earthMuted)
            }
            if !stacks { Spacer() }
            action(for: state)
        }
        .padding(.vertical, 2)
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
            Image(wkt: .warning).wktIcon(.inline, tint: .earthOrange)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Needs a newer version of Wockett")
        }
    }

    private func downloadButton(title: String) -> some View {
        Button {
            Task { await library.download(record) }
        } label: {
            Label { Text(title) } icon: { Image(wkt: .cloudDownload).wktIcon(.inline, tint: .earthGreen) }
                .font(.wktBodyText)
                .foregroundColor(.earthGreen)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(record.regionName)")
    }
}

enum TrailRegionText {
    private static let size = ByteCountFormatStyle(style: .file)

    /// A row's second line. A date or size shows only where it is known: the
    /// date from the pack on this phone, the size from the catalogue (what a
    /// download costs; the file on the phone is not measured).
    static func detail(state: TrailPackLibrary.RegionState, record: TrailRegionRecord, dataDate: Date?) -> String {
        let count = "\(record.trailCount.formatted()) trails"
        let size: String? = record.sizeBytes > 0 ? "\(record.sizeBytes.formatted(Self.size)) download size" : nil
        let date = dataDate.map { "Data from \($0.formatted(date: .abbreviated, time: .omitted))" }
        let parts: [String?]
        switch state {
        case .bundled: parts = ["Named trails included", date, "full pack \(count)", size]
        case .installed: parts = ["Installed", count, date]
        case .updateAvailable: parts = ["Update available", count, size, date]
        case .available: parts = [count, size]
        case .needsAppUpdate: return "Needs a newer version of Wockett"
        case .downloading(let p): return p > 0 ? "Downloading \(Int(p * 100))%…" : "Downloading…"
        case .failed(let why): return why
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}
