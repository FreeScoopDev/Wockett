import SwiftUI
import CloudKit
import Combine
import MapKit

// MARK: - Route Card

struct RouteCard: View {
    let route: SuggestedRoute
    let isSelected: Bool
    let totalRoutes: Int
    var isSaved: Bool = false
    let onSelect: () -> Void
    var onSave: (() -> Void)? = nil
    var onPost: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

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
                    // Side by side at the accessibility sizes, the two squeezed
                    // each other to one character a line ("6. / 3 / mi" on an
                    // iPhone 17e). Stacked, each value keeps its unit.
                    let valueRow = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout(spacing: 14))
                    valueRow {
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var deletion: CommunityDeletionRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(route.name)
                        .font(.wktRowTitle).foregroundColor(.earthCream)
                    Text("by \(route.authorName)")
                        .font(.wktLabel).foregroundColor(.earthMuted)
                        .lineLimit(WktNameLayout.authorLineLimit(typeSize))
                }
                Spacer()
                DifficultyBadge(difficulty: route.difficulty, compact: true)
            }

            // At the accessibility sizes the stats stack and Start Walk takes a
            // row of its own: side by side, at Accessibility 2 the values split
            // ("9.1 / mi", "2h / 54m") and the card's only action read "Start…"
            // (spec fix/large-text-round2, item 1). As `RouteCard` does.
            let stacks = WktNameLayout.stacks(typeSize)
            let start = WktPillButton(title: "Start Walk", action: onStart)
            let statRow = stacks
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(spacing: 16))
            statRow {
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

                if !stacks { start }
            }

            if stacks { start }
        }
        .wktCard()
        .contextMenu {
            if let onHide {
                CommunityReportButton("Report Route", author: route.author) { report = CommunityReport(route: route) }
                CommunityBlockButton(author: route.author, onHide: onHide)
                CommunityDeleteButton(author: route.author) { deletion = CommunityDeletionRequest(kind: .route, recordID: route.id) }
            }
        }
        .communityReporting($report, onHide: { _ in onHide?() })
        .communityDeleting($deletion) { _ in onHide?() }
    }
}

// MARK: - Post to Community Sheet

/// A form that scrolls at the accessibility sizes only (Share Achievement).
/// Fixed to the sheet, at Accessibility 2 the old Share Route form ran past
/// the bottom: Cancel over the tiles, the Post button cut to "Post & Save to
/// My Rou…". Share Route now scrolls at every size: its map preview makes it
/// taller than an iPhone 17e sheet.
struct ScrollsAtAccessibilitySizes: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            ScrollView { content }
        } else {
            content
        }
    }
}

/// A suggested route's Share: its stats and the name it goes out under, then
/// the review every share goes through.
struct PostToCommunitySheet: View {
    let route: SuggestedRoute
    @ObservedObject var routeStore: CustomRouteStore
    let onSaved: () -> Void

    @State private var routeName = ""
    /// The path a share publishes, made once when the sheet appears.
    @State private var shareRoute: CustomRoute?

    var body: some View {
        ShareReviewSheet(source: shareRoute, isLoadingSource: shareRoute == nil, name: routeName,
                         publishTitle: "Post & Save to My Routes", publishSymbol: .share, onPublished: {
            routeStore.save(route.toCustomRoute(name: routeName.trimmingCharacters(in: .whitespaces)))
            onSaved()
        }, fields: {
            WktStatRow {
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
        })
        .onAppear {
            routeName = route.label ?? "\(route.directionName) \(route.isLoop ? "Loop" : "Route")"
            if shareRoute == nil { shareRoute = route.shareableRoute(name: "") }
        }
    }
}

/// The one screen a route is published from, for both Share buttons (a saved
/// route's detail, a suggested route's card). Everything that decides what
/// goes public sits above Publish: who can see it, the name it goes out
/// under, the home warning, a map of exactly the path that will be published,
/// Hide start and finish, and the shared length.
struct ShareReviewSheet<Fields: View>: View {
    /// The path to share; nil while it loads (`isLoadingSource`) or when it can't.
    let source: CustomRoute?
    let isLoadingSource: Bool
    /// The route name it is published under.
    let name: String
    let publishTitle: String
    var publishSymbol: WktSymbol = .upload
    var publisher: SharedRoutePublishing = CommunityRouteService.shared
    /// After the route is published, before the sheet closes.
    let onPublished: () -> Void
    /// What the entry point adds above the review, such as a name field.
    @ViewBuilder let fields: () -> Fields

    @Environment(\.dismiss) private var dismiss
    @State private var isPosting = false
    @State private var didPost = false
    @State private var errorMessage: String?
    /// Holds a community action until the Terms are agreed to (CommunityTermsGate).
    @State private var termsGate = CommunityTermsGate()
    /// Hide start and finish: the user's last choice, on if they never chose.
    @AppStorage(SharedRouteTrim.hideEndsKey) private var hideEnds = SharedRouteTrim.hideEndsDefault
    /// The user's privacy offset, fetched only once Hide start and finish is on.
    @State private var shareOffset: SharePrivacyOffset?
    @State private var shareOffsetChecked = false
    @State private var shareOffsetAttempt = 0

    var body: some View {
        // Worked out once per render: the map draws, and Publish sends, this one value.
        let review = ShareReview(route: source, hideEnds: hideEnds, offset: shareOffset)
        let isPreparing = isLoadingSource || (review.route != nil && hideEnds && !shareOffsetChecked)
        let canShare = !isPreparing && review.trimmed != nil
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: WktSpacing.betweenSections) {
                        fields()
                        audience
                        if !isPreparing, let trimmed = review.trimmed { preview(trimmed) }
                        RouteSharePrivacyNote(outcome: review.outcome, hideEnds: $hideEnds,
                                              isPreparing: isPreparing, onRetry: { shareOffsetAttempt += 1 })
                            .disabled(isPosting || didPost)

                        if let err = errorMessage {
                            Text(err)
                                .font(.wktLabel).foregroundColor(.earthOrange)
                                .multilineTextAlignment(.center)
                        }

                        Button { termsGate.perform { post(review) } } label: {
                            WktBusyLabel(isBusy: isPosting) {
                                WktPrimaryLabel(title: didPost ? "Shared!" : publishTitle,
                                                symbol: didPost ? .success : publishSymbol)
                                    .opacity(didPost ? 0.6 : 1)
                            } busy: {
                                ProgressView().tint(.white)
                            }
                        }
                        .buttonStyle(BounceButtonStyle(scale: 0.98))
                        .disabled(isPosting || didPost || !canShare || name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("routes.sharePublish")
                    }
                    .padding(.horizontal, WktSpacing.screen)
                    .padding(.vertical, 24)
                }
            }
            .navigationTitle("Share Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.earthMuted)
                        // Open until the post ends, so a failure is seen.
                        .disabled(isPosting)
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
        .communityTermsSheet($termsGate)
        .presentationDetents([.large])
        .interactiveDismissDisabled(isPosting)
        .task(id: "\(hideEnds)-\(shareOffsetAttempt)") {
            guard hideEnds, shareOffset == nil else { return }
            shareOffsetChecked = false
            let offset = await SharePrivacyOffsetStore.shared.currentIfAvailable()
            // Superseded (an account change started another fetch): leave it to that one.
            guard !Task.isCancelled else { return }
            shareOffset = offset
            shareOffsetChecked = true
        }
        // Another iCloud account has another offset (SharePrivacyOffsetStore
        // forgets its own): fetch it again rather than publish with this one.
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged).receive(on: DispatchQueue.main)) { _ in
            shareOffset = nil
            shareOffsetAttempt += 1
        }
    }

    /// Who can see it, the name it goes out under, and the home warning.
    private var audience: some View {
        VStack(alignment: .leading, spacing: WktSpacing.betweenCards) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Anyone using Wockett can see this route")
                    .font(.wktBodyText).foregroundColor(.earthCream)
                Text("Posting as \(CommunityNameService.shared.displayName)")
                    .font(.wktLabel).foregroundColor(.earthMuted)
                    // The name a share would really go out under, checked without claiming.
                    .task { await CommunityNameService.shared.refreshDisplayName() }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(wkt: .warning).wktIcon(.inline, tint: .earthOrange)
                Text(SharedRouteTrim.homeWarning)
                    .font(.wktLabel)
                    .foregroundColor(.earthCream)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("routes.shareHomeWarning")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wktCard()
    }

    /// The path Publish sends, as other people will see it.
    private func preview(_ trimmed: SharedRouteTrim.Trimmed) -> some View {
        Map(initialPosition: .automatic, interactionModes: []) {
            MapPolyline(coordinates: trimmed.waypoints.map(\.clCoordinate))
                .stroke(source?.activityMode.tileColor ?? .earthGreen, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        .mapStyle(.standard(emphasis: .muted))
        // A new map when hiding changes the path, so it fits the path it shows.
        .id(trimmed.hidesEnds)
        .frame(height: 180)
        .clipShape(RoundedRectangle.wktCard)
        .overlay(RoundedRectangle.wktCard.strokeBorder(Color.earthStroke, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map of the route as it will be shared")
        .accessibilityIdentifier("routes.sharePreview")
    }

    private func post(_ review: ShareReview) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isPosting = true
        errorMessage = nil
        Task {
            let container = CKContainer(identifier: WockettCloud.containerID)
            let status = try? await container.accountStatus()
            guard status == .available else {
                errorMessage = "Sign in to iCloud in the Settings app to share routes."
                isPosting = false
                return
            }
            do {
                try await review.publish(name: name, with: publisher)
                onPublished()
                didPost = true
                try? await Task.sleep(nanoseconds: 900_000_000)
                dismiss()
            } catch let access as CommunityAccessError {
                errorMessage = access.message
                isPosting = false
            } catch let cannot as SharedRouteTrim.CannotShareError {
                errorMessage = cannot.message
                isPosting = false
            } catch let invalid as ContentFilter.ValidationError {
                errorMessage = invalid.errorDescription
                isPosting = false
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
