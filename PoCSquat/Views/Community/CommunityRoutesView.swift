import SwiftUI
import CloudKit

// MARK: - Community Routes Model

@Observable
final class CommunityRoutesModel {
    var routes: [SharedRoute] = []
    var isLoading = false
    var loadError: String? = nil
    private(set) var didLoad = false

    /// Set when a Wockett failed to save. Both route screens show it, so each
    /// clears it when it appears: a message is about a tap on that screen.
    var wocketError: String?
    /// Saves a Wockett. A seam for tests; the app saves a CommunityVote.
    var saveWockett: (CKRecord.ID) async throws -> Void = { try await CommunityRouteService.shared.wockett(id: $0) }
    /// Where Wocketted routes are remembered (a seam for tests).
    var wockettMarks = VoteMarks.wocketts
    /// Wocketts still saving: a refresh mid-save adds them back (OptimisticVote).
    var pendingVotes: Set<String> = []

    /// Shows freshly fetched routes, keeping Wocketts that are still saving.
    func show(_ fetched: [SharedRoute]) {
        routes = OptimisticVote.withPending(fetched, pending: pendingVotes, counted: wockettMarks.has,
                                            idPath: \.id, count: \.wocketts)
    }

    /// Wocketted: saved and remembered, or still saving.
    func hasVoted(_ id: CKRecord.ID) -> Bool {
        wockettMarks.has(id) || pendingVotes.contains(id.recordName)
    }

    /// Gives `id` a Wockett at once and saves it; a failed save is taken back
    /// by id and reported in `wocketError`. One place for both route screens.
    /// Returns the save, for tests to await.
    @discardableResult
    func wockett(_ id: CKRecord.ID) -> Task<Void, Never>? {
        wocketError = nil
        return OptimisticVote.vote(id, on: self, list: \.routes, pending: \.pendingVotes, idPath: \.id, count: \.wocketts,
                                   marks: wockettMarks, save: saveWockett,
                                   failed: { [weak self] in self?.wocketError = CommunityVotes.failureMessage($0, noun: "Wockett") })
    }

    func load(force: Bool = false) async {
        guard !isLoading else { return }
        guard force || !didLoad else { return }
        isLoading = true
        loadError = nil
        Task { await MyAccount.refresh() }
        do {
            Task { await UnsentVoteCatchUp.runIfNeeded() }
            show(try await CommunityRouteService.shared.fetchRoutes())
            didLoad = true
        } catch let ck as CKError {
            loadError = ckMessage(ck)
        } catch {
            loadError = "Couldn't load community routes. Check your connection and try again."
        }
        isLoading = false
    }

    private func ckMessage(_ ck: CKError) -> String {
        switch ck.code {
        case .notAuthenticated:
            return "Sign in to iCloud in the Settings app to view community routes."
        case .networkUnavailable, .networkFailure:
            return "No internet connection. Check your connection and retry."
        case .unknownItem, .invalidArguments, .internalError:
            return "Community routes aren't available right now. Please try again later."
        case .serviceUnavailable:
            return "iCloud is temporarily unavailable. Try again in a moment."
        default:
            return "Couldn't load community routes. Please try again."
        }
    }
}

// MARK: - Community Routes View

struct CommunityRoutesView: View {
    @Environment(CommunityRoutesModel.self) private var model
    @EnvironmentObject private var routeStore: CustomRouteStore
    @EnvironmentObject private var tabRouter: TabRouter

    @State private var savedIds: Set<String> = []
    @State private var showActiveSessionAlert = false

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()

            if model.isLoading && model.routes.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().tint(.earthGreen)
                    Text("Loading routes…")
                        .font(.wktBodyText).foregroundColor(.earthMuted)
                }
            } else if let err = model.loadError, model.routes.isEmpty {
                errorState(err)
            } else if model.routes.isEmpty && model.didLoad {
                emptyState
            } else {
                routeList
            }
        }
        .navigationTitle("Community Routes")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .onAppear { model.wocketError = nil }   // the other route screen's message isn't about a tap here
        .alert("Session Already Active", isPresented: $showActiveSessionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You have a session in progress. Return to home to resume or end it first.")
        }
    }

    private var routeList: some View {
        ScrollView {
            LazyVStack(spacing: WktSpacing.betweenCards) {
                if let err = model.wocketError {
                    HStack(spacing: 6) {
                        Image(wkt: .errorCircle).wktIcon(.inline, tint: .earthOrange, filled: true)
                        Text(err).font(.wktLabel)
                    }
                    .foregroundColor(.earthOrange)
                    .transition(.opacity)
                }
                ForEach(Array(model.routes.enumerated()), id: \.element.id) { i, route in
                    CommunityRouteCard(
                        route: Binding(
                            get: { i < model.routes.count ? model.routes[i] : route },
                            set: { if i < model.routes.count { model.routes[i] = $0 } }
                        ),
                        hasVoted: model.hasVoted(route.id),
                        isSaved: savedIds.contains(route.id.recordName),
                        onWockett: { handleWockett(at: i) },
                        onSave: { handleSave(at: i) },
                        onStart: { handleStart(at: i) },
                        onHide: { model.routes.removeAll { $0.id == route.id || CommunityModerationStore.shared.shouldHide(id: $0.id, author: $0.author) } }
                    )
                }
            }
            .padding(.horizontal, WktSpacing.screen)
            .padding(.top, 12)
            .padding(.bottom, WktSpacing.betweenSections)
            .animation(.easeInOut(duration: 0.2), value: model.wocketError != nil)
        }
        .refreshable { await model.load(force: true) }
    }

    private var emptyState: some View {
        WktEmptyState(symbol: .communityRoutes, tint: .earthGreen,
                      title: "No routes shared yet",
                      message: "Share a route from Route Finder to be the first!")
    }

    private func errorState(_ message: String) -> some View {
        WktEmptyState(symbol: .cloudError, message: message, actionTitle: "Retry") {
            Task { await model.load(force: true) }
        }
    }

    private func handleWockett(at i: Int) {
        guard i < model.routes.count else { return }
        model.wockett(model.routes[i].id)
    }

    private func handleSave(at i: Int) {
        guard i < model.routes.count else { return }
        let route = model.routes[i]
        routeStore.save(CustomRoute(
            id: UUID(), name: route.name, waypoints: route.waypoints,
            totalDistance: route.distanceMeters, isLoop: route.isLoop,
            createdAt: Date()
        ))
        savedIds.insert(route.id.recordName)
        let count = UserDefaults.standard.integer(forKey: "wkt_routesBookmarked_count")
        UserDefaults.standard.set(count + 1, forKey: "wkt_routesBookmarked_count")
    }

    private func handleStart(at i: Int) {
        guard i < model.routes.count else { return }
        var nav = model.routes[i].toNavigableRoute()
        nav.isCommunityRoute = true
        guard ActiveWalkStore.shared.beginSession(route: nav) != nil else {
            showActiveSessionAlert = true
            return
        }
        tabRouter.selected = .home
    }
}
