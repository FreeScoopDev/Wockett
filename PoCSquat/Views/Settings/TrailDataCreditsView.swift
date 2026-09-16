import SwiftUI

// MARK: - TrailDataCreditsView
//
// The rows in Settings → About that say where trail data comes from. Two
// jobs, both driven by what is actually loaded rather than by copy in this
// file: the data's region and build date (so stale data is visible), and the
// licence line each source requires. ODbL attribution for OpenStreetMap is a
// legal obligation; it comes from the pack via `TrailAttributionRegistry`, so
// it can never drift from the data it credits and never needs editing here.
// OSMF's guidelines accept an About screen credit with a link for mobile apps.

struct TrailDataCreditsView: View {
    @Environment(\.openURL) private var openURL
    private var library: TrailPackLibrary { .shared }
    private var registry: TrailAttributionRegistry { .shared }

    // A pack's build date is a calendar day of the data, stamped in UTC by the
    // builder. Shown in UTC too, or 2026-09-16T00:00Z reads as "Sep 15" on the
    // US east coast — seen on the simulator on 2026-09-16.
    private static let builtFormat: Date.FormatStyle = {
        var style: Date.FormatStyle = .dateTime.day().month(.abbreviated).year()
        style.timeZone = TimeZone(identifier: "UTC") ?? .current
        return style
    }()

    var body: some View {
        if !library.packInfos.isEmpty || !registry.attributions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Trail data").font(.subheadline).foregroundColor(.earthCream)

                ForEach(library.packInfos, id: \.region) { info in
                    Text(describe(info))
                        .font(.caption).foregroundColor(.earthMuted)
                }

                ForEach(registry.attributions) { attribution in
                    Button {
                        if let url = attribution.url { openURL(url) }
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(attribution.attribution) · \(attribution.license)")
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                            if attribution.url != nil {
                                Image(wkt: .openExternal).wktIcon(.inline, tint: .earthGreen)
                            }
                        }
                        .foregroundColor(.earthGreen)
                    }
                    .buttonStyle(.plain)
                    .disabled(attribution.url == nil)
                    .accessibilityLabel("Trail data credit: \(attribution.attribution), \(attribution.license)")
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.earthCard)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.trailData")
        }
    }

    private func describe(_ info: TrailPackInfo) -> String {
        var parts = ["\(info.regionName): \(info.trailCount.formatted()) trails"]
        if let built = info.builtAt {
            parts.append("data from \(built.formatted(Self.builtFormat))")
        }
        return parts.joined(separator: ", ")
    }
}
