import SwiftUI
import CloudKit

// MARK: - Community Routes Model

@Observable
final class CommunityRoutesModel {
    var routes: [SharedRoute] = []
    var isLoading = false
    var loadError: String? = nil
    private(set) var didLoad = false

    func load(force: Bool = false) async {
        guard !isLoading else { return }
        guard force || !didLoad else { return }
        isLoading = true
        loadError = nil
        do {
            routes = try await CommunityRouteService.shared.fetchRoutes()
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
    @State private var wocketError: String? = nil
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
        .alert("Session Already Active", isPresented: $showActiveSessionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You have a session in progress. Return to home to resume or end it first.")
        }
    }

    private var routeList: some View {
        ScrollView {
            LazyVStack(spacing: WktSpacing.betweenCards) {
                if let err = wocketError {
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
                        hasVoted: CommunityRouteService.shared.hasVoted(for: route.id),
                        isSaved: savedIds.contains(route.id.recordName),
                        onWockett: { handleWockett(at: i) },
                        onSave: { handleSave(at: i) },
                        onStart: { handleStart(at: i) },
                        onHide: { model.routes.removeAll { $0.id == route.id } }
                    )
                }
            }
            .padding(.horizontal, WktSpacing.screen)
            .padding(.top, 12)
            .padding(.bottom, WktSpacing.betweenSections)
            .animation(.easeInOut(duration: 0.2), value: wocketError != nil)
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
        let route = model.routes[i]
        guard !CommunityRouteService.shared.hasVoted(for: route.id) else { return }
        model.routes[i].wocketts += 1
        CommunityRouteService.shared.markVoted(for: route.id)
        Task {
            do { try await CommunityRouteService.shared.wockett(id: route.id) }
            catch { wocketError = "Couldn't save your Wockett — check your connection." }
        }
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
