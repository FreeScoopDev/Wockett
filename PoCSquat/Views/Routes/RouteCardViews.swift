import SwiftUI
import CloudKit

// MARK: - Route Card

struct RouteCard: View {
    let route: SuggestedRoute
    let isSelected: Bool
    let totalRoutes: Int
    var isSaved: Bool = false
    let onSelect: () -> Void
    var onSave: (() -> Void)? = nil
    var onPost: (() -> Void)? = nil

    private var routeColor: Color {
        SuggestedRoute.paletteColor(index: route.colorIndex, total: totalRoutes)
    }

    private var cardIcon: WktSymbol {
        route.label != nil ? .loop : .arrowUp
    }

    /// Compass heading for the arrow; one glyph turned, not eight symbol names.
    private var cardIconAngle: Double {
        guard route.label == nil else { return 0 }
        switch route.directionName {
        case "North":     return 0
        case "Northeast": return 45
        case "East":      return 90
        case "Southeast": return 135
        case "South":     return 180
        case "Southwest": return 225
        case "West":      return 270
        default:          return 315
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                // The route's own map colour, so the card and its line match.
                Image(wkt: cardIcon)
                    .wktIcon(.row, tint: routeColor)
                    .rotationEffect(.degrees(cardIconAngle))
                    .frame(width: 48, height: 48)
                    .background(routeColor.opacity(isSelected ? 0.3 : 0.16),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(route.label ?? "\(route.directionName) \(route.isLoop ? "loop" : "route")")
                        .font(.wktRowTitle).foregroundColor(.earthCream)
                    HStack(spacing: 14) {
                        Label { Text(route.distanceText) } icon: { Image(wkt: .distance).wktIcon(.inline, tint: .earthMuted) }
                        Label { Text(route.timeText) }     icon: { Image(wkt: .time).wktIcon(.inline, tint: .earthMuted) }
                    }
                    .font(.wktLabel).foregroundColor(.earthMuted)
                    if let elev = route.elevationSummary {
                        Text(elev)
                            .font(.wktLabel).foregroundColor(routeColor)
                    }
                    HStack(spacing: 8) {
                        Text("~\(route.estimatedSteps.formatted()) steps")
                            .font(.wktLabel).foregroundColor(.earthGreen)
                        DifficultyBadge(difficulty: .fromDistance(route.perLapDistance), compact: true)
                        if route.lapCount > 1 {
                            WktStatusChip(text: "×\(route.lapCount) laps", dot: .earthOrange)
                        }
                    }
                }

                Spacer()

                VStack(spacing: 10) {
                    if isSelected {
                        Image(wkt: .success)
                            .wktIcon(.row, tint: routeColor, filled: true)
                    }
                    if let onSave {
                        Button(action: onSave) {
                            Image(wkt: .saved)
                                .wktIcon(.inline, tint: isSaved ? routeColor : .earthMuted, filled: isSaved)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaved)
                        .accessibilityLabel("Save route")
                        .accessibilityValue(isSaved ? "Saved" : "Not saved")
                        .accessibilityAddTraits(isSaved ? .isSelected : [])
                    }
                    if let onPost {
                        Button(action: onPost) {
                            Image(wkt: .share).wktIcon(.row, tint: .earthMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Share route")
                    }
                }
            }
            // wktCard's shape, with the selected route's tint and stroke.
            .padding(WktSpacing.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(isSelected ? routeColor.opacity(0.1) : Color.earthCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(isSelected ? routeColor.opacity(0.5) : Color.earthStroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Community Route Card

struct CommunityRouteCard: View {
    @Binding var route: SharedRoute
    let hasVoted: Bool
    var isSaved: Bool = false
    let onWockett: () -> Void
    var onSave: (() -> Void)? = nil
    let onStart: () -> Void
    var onHide: (() -> Void)? = nil
    @State private var report: CommunityReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(route.name)
                        .font(.wktRowTitle).foregroundColor(.earthCream)
                    Text("by \(route.authorName)")
                        .font(.wktLabel).foregroundColor(.earthMuted)
                }
                Spacer()
                DifficultyBadge(difficulty: route.difficulty, compact: true)
            }

            HStack(spacing: 16) {
                Label { Text(route.distanceText) } icon: { Image(wkt: .distance).wktIcon(.inline, tint: .earthMuted) }
                Label { Text(route.timeText) } icon: { Image(wkt: .time).wktIcon(.inline, tint: .earthMuted) }
                Label { Text("\(route.estimatedSteps.formatted()) steps") } icon: { Image(wkt: .walk).wktIcon(.inline, tint: .earthMuted) }
            }
            .font(.wktLabel).foregroundColor(.earthMuted)

            HStack {
                Button(action: onWockett) {
                    HStack(spacing: 5) {
                        Image(wkt: .wockett)
                            .wktIcon(.inline, tint: hasVoted ? .earthGreen : .earthMuted, filled: hasVoted)
                        Text(hasVoted
                             ? "\(route.wocketts) Wocketted!"
                             : "\(route.wocketts) Wockett\(route.wocketts == 1 ? "" : "s")")
                            .font(.wktLabel)
                    }
                    .foregroundColor(hasVoted ? .earthGreen : .earthMuted)
                    .frame(minHeight: 44)
                    .animation(.spring(duration: 0.2), value: hasVoted)
                }
                .disabled(hasVoted)

                Spacer()

                if let onSave {
                    Button(action: onSave) {
                        Image(wkt: .saved)
                            .wktIcon(.inline, tint: isSaved ? .earthGreen : .earthCream, filled: isSaved)
                            .frame(width: 36, height: 36)
                            .background(Color.earthRaised, in: Circle())
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .disabled(isSaved)
                    .accessibilityLabel("Save route")
                    .accessibilityValue(isSaved ? "Saved" : "Not saved")
                    .accessibilityAddTraits(isSaved ? .isSelected : [])
                }

                WktPillButton(title: "Start Walk", action: onStart)
            }
        }
        .wktCard()
        .contextMenu {
            if let onHide {
                Button(role: .destructive) {
                    report = CommunityReport(route: route)
                } label: {
                    Label {
                        Text("Report Route")
                    } icon: {
                        Image(wkt: .flagReport).wktIcon(.inline, tint: .red)
                    }
                }
                Button(role: .destructive) {
                    CommunityModerationStore.shared.block(author: route.authorName)
                    onHide()
                } label: {
                    Label {
                        Text("Block \(route.authorName)")
                    } icon: {
                        Image(wkt: .blockUser).wktIcon(.inline, tint: .red)
                    }
                }
            }
        }
        .communityReporting($report, onHide: onHide)
    }
}

// MARK: - Post to Community Sheet

struct PostToCommunitySheet: View {
    let route: SuggestedRoute
    @ObservedObject var routeStore: CustomRouteStore
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var routeName = ""
    @State private var isPosting = false
    @State private var didPost = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                VStack(spacing: WktSpacing.betweenSections) {
                    HStack(spacing: WktSpacing.betweenCards) {
                        WktIconStatTile(value: route.distanceText, label: "Distance", symbol: .distance)
                        WktIconStatTile(value: route.timeText,     label: "Time",     symbol: .time)
                        WktIconStatTile(value: "~\(route.estimatedSteps.formatted())", label: "Steps", symbol: .walk)
                    }

                    WktSection(title: "Route name") {
                        TextField("Name your route…", text: $routeName)
                            .font(.wktBodyText)
                            .foregroundColor(.earthCream)
                            .padding(.horizontal, WktSpacing.cardPadding)
                            .frame(minHeight: 52)
                            .wktCardBackground()
                    }

                    if let err = errorMessage {
                        Text(err)
                            .font(.wktLabel).foregroundColor(.earthOrange)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: post) {
                        if isPosting {
                            ProgressView().tint(.white)
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .background(Color.earthGreenFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        } else {
                            WktPrimaryLabel(title: didPost ? "Shared!" : "Post & Save to My Routes",
                                            symbol: didPost ? .success : .share)
                                .opacity(didPost ? 0.6 : 1)
                        }
                    }
                    .buttonStyle(BounceButtonStyle(scale: 0.98))
                    .disabled(isPosting || didPost || routeName.trimmingCharacters(in: .whitespaces).isEmpty)

                    Spacer()
                }
                .padding(.horizontal, WktSpacing.screen)
                .padding(.top, 24)
            }
            .navigationTitle("Share Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.earthMuted)
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
        .presentationDetents([.medium])
        .onAppear {
            routeName = route.label ?? "\(route.directionName) \(route.isLoop ? "Loop" : "Route")"
        }
    }

    private func post() {
        let name = routeName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isPosting = true
        errorMessage = nil
        let customRoute = route.toCustomRoute(name: name)
        Task {
            let container = CKContainer(identifier: "iCloud.Scoops.PoCSquat")
            let status = try? await container.accountStatus()
            guard status == .available else {
                errorMessage = "Sign in to iCloud in the Settings app to share routes."
                isPosting = false
                return
            }
            do {
                try await CommunityRouteService.shared.publish(route: customRoute)
                routeStore.save(customRoute)
                onSaved()
                didPost = true
                try? await Task.sleep(nanoseconds: 900_000_000)
                dismiss()
            } catch let ckError as CKError {
                switch ckError.code {
                case .notAuthenticated:
                    errorMessage = "Sign in to iCloud in the Settings app to share routes."
                case .networkUnavailable, .networkFailure:
                    errorMessage = "No internet connection. Try again when online."
                case .unknownItem, .invalidArguments:
                    errorMessage = "Sharing isn't available right now. Please try again later."
                case .permissionFailure:
                    errorMessage = "iCloud permission denied. Check app settings."
                default:
                    errorMessage = "Couldn't share this route. Please try again."
                }
                isPosting = false
            } catch {
                errorMessage = "Couldn't share this route. Check your connection and try again."
                isPosting = false
            }
        }
    }
}
