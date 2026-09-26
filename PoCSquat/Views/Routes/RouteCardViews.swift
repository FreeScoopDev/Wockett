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
                ZStack {
                    Circle()
                        .fill(routeColor.opacity(isSelected ? 0.3 : 0.18))
                        .frame(width: 54, height: 54)
                    Image(wkt: cardIcon)
                        .wktIcon(.row, tint: routeColor)
                        .rotationEffect(.degrees(cardIconAngle))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(route.label ?? "\(route.directionName) \(route.isLoop ? "loop" : "route")")
                        .font(.wktHeading(17)).foregroundColor(.earthCream)
                    HStack(spacing: 14) {
                        Label { Text(route.distanceText) } icon: { Image(wkt: .distance).wktIcon(.inline, tint: .earthMuted) }
                        Label { Text(route.timeText) }     icon: { Image(wkt: .time).wktIcon(.inline, tint: .earthMuted) }
                    }
                    .font(.wktBody(13)).foregroundColor(.earthMuted)
                    if let elev = route.elevationSummary {
                        Text(elev)
                            .font(.wktBody(12)).foregroundColor(routeColor.opacity(0.85))
                    }
                    HStack(spacing: 8) {
                        Text("~\(route.estimatedSteps.formatted()) steps")
                            .font(.wktBody(13)).foregroundColor(.earthGreen)
                        DifficultyBadge(difficulty: .fromDistance(route.perLapDistance), compact: true)
                        if route.lapCount > 1 {
                            Text("×\(route.lapCount) laps")
                                .font(.wktBody(12)).foregroundColor(.earthOrange)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.earthOrange.opacity(0.15))
                                .cornerRadius(20)
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
            // wktCard's shape, kept custom for the selected tint and stroke.
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? routeColor.opacity(0.1) : Color.earthCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isSelected ? routeColor.opacity(0.5) : Color.earthMuted.opacity(0.15), lineWidth: 1)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(route.name)
                        .font(.wktHeading(17)).foregroundColor(.earthCream)
                    Text("by \(route.authorName)")
                        .font(.wktBody(12)).foregroundColor(.earthMuted)
                }
                Spacer()
                DifficultyBadge(difficulty: route.difficulty, compact: true)
            }

            HStack(spacing: 16) {
                Label { Text(route.distanceText) } icon: { Image(wkt: .distance).wktIcon(.inline, tint: .earthMuted) }
                Label { Text(route.timeText) } icon: { Image(wkt: .time).wktIcon(.inline, tint: .earthMuted) }
                Label { Text("\(route.estimatedSteps.formatted()) steps") } icon: { Image(wkt: .walk).wktIcon(.inline, tint: .earthMuted) }
            }
            .font(.wktBody(12)).foregroundColor(.earthMuted)

            HStack {
                Button(action: onWockett) {
                    HStack(spacing: 5) {
                        Image(wkt: .wockett)
                            .wktIcon(.inline, tint: hasVoted ? .earthGreen : .earthMuted, filled: hasVoted)
                        Text(hasVoted
                             ? "\(route.wocketts) Wocketted!"
                             : "\(route.wocketts) Wockett\(route.wocketts == 1 ? "" : "s")")
                            .font(.wktBody(15))
                    }
                    .foregroundColor(hasVoted ? .earthGreen : .earthMuted)
                    .animation(.spring(duration: 0.2), value: hasVoted)
                }
                .disabled(hasVoted)

                Spacer()

                if let onSave {
                    Button(action: onSave) {
                        Image(wkt: .saved)
                            .wktIcon(.inline, tint: isSaved ? .earthGreen : .earthMuted, filled: isSaved)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Color.earthCard)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.earthMuted.opacity(0.2), lineWidth: 1))
                    }
                    .disabled(isSaved)
                    .accessibilityLabel("Save route")
                    .accessibilityValue(isSaved ? "Saved" : "Not saved")
                    .accessibilityAddTraits(isSaved ? .isSelected : [])
                }

                Button(action: onStart) {
                    Label {
                        Text("Start Walk")
                    } icon: {
                        Image(wkt: .walk).wktIcon(.inline, tint: .white, onFill: true)
                    }
                    .font(.wktBody(15))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.earthGreenFill).foregroundColor(.white)
                    .cornerRadius(10)
                }
            }
        }
        .wktCard()
        .contextMenu {
            if let onHide {
                Button(role: .destructive) {
                    CommunityModerationStore.shared.report(route.id)
                    onHide()
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
                VStack(spacing: 28) {
                    HStack(spacing: 12) {
                        statTile(value: route.distanceText, label: "Distance", icon: .distance)
                        statTile(value: route.timeText,     label: "Time",     icon: .time)
                        statTile(value: "~\(route.estimatedSteps.formatted())", label: "Steps", icon: .walk)
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 8) {
                        WktSectionHeader(title: "Route name")
                            .padding(.horizontal)
                        TextField("Name your route…", text: $routeName)
                            .foregroundColor(.earthCream)
                            .padding(14)
                            .background(Color.earthCard)
                            .cornerRadius(12)
                            .padding(.horizontal)
                    }

                    if let err = errorMessage {
                        Text(err)
                            .font(.wktBody(12)).foregroundColor(.earthOrange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Button(action: post) {
                        Group {
                            if isPosting {
                                ProgressView().tint(.white)
                            } else if didPost {
                                Label {
                                    Text("Shared!")
                                } icon: {
                                    Image(wkt: .success).wktIcon(.row, tint: .white, filled: true, onFill: true)
                                }
                            } else {
                                Label {
                                    Text("Post & Save to My Routes")
                                } icon: {
                                    Image(wkt: .share).wktIcon(.row, tint: .white, onFill: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(didPost ? Color.earthGreenFill.opacity(0.6) : Color.earthGreenFill)
                        .foregroundColor(.white)
                        .font(.wktBody(17))
                        .cornerRadius(14)
                        .padding(.horizontal)
                    }
                    .disabled(isPosting || didPost || routeName.trimmingCharacters(in: .whitespaces).isEmpty)

                    Spacer()
                }
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

    private func statTile(value: String, label: String, icon: WktSymbol) -> some View {
        VStack(spacing: 6) {
            Image(wkt: icon).wktIcon(.row, tint: .earthGreen)
            Text(value).font(.wktHeading(17)).foregroundColor(.earthCream)
            Text(label).font(.wktBody(12)).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity)
        // Third-width tiles: 12 pt sides leave room for "12.4 km" on one line.
        .padding(.vertical, 4)
        .wktCard(padding: 12)
    }
}
