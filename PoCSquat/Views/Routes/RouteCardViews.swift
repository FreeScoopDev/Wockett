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

    private var cardIcon: String {
        if route.label != nil { return "arrow.triangle.2.circlepath" }
        switch route.directionName {
        case "North":     return "arrow.up"
        case "Northeast": return "arrow.up.right"
        case "East":      return "arrow.right"
        case "Southeast": return "arrow.down.right"
        case "South":     return "arrow.down"
        case "Southwest": return "arrow.down.left"
        case "West":      return "arrow.left"
        default:          return "arrow.up.left"
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(routeColor.opacity(isSelected ? 0.3 : 0.18))
                        .frame(width: 54, height: 54)
                    Image(systemName: cardIcon)
                        .foregroundColor(routeColor)
                        .font(.title3)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(route.label ?? "\(route.directionName) \(route.isLoop ? "loop" : "route")")
                        .font(.headline).foregroundColor(.earthCream)
                    HStack(spacing: 14) {
                        Label(route.distanceText, systemImage: "ruler")
                        Label(route.timeText,     systemImage: "clock")
                    }
                    .font(.footnote).foregroundColor(.earthMuted)
                    if let elev = route.elevationSummary {
                        Text(elev)
                            .font(.caption).foregroundColor(routeColor.opacity(0.85))
                    }
                    HStack(spacing: 8) {
                        Text("~\(route.estimatedSteps.formatted()) steps")
                            .font(.footnote).foregroundColor(.earthGreen)
                        DifficultyBadge(difficulty: .fromDistance(route.perLapDistance), compact: true)
                        if route.lapCount > 1 {
                            Text("×\(route.lapCount) laps")
                                .font(.caption.bold()).foregroundColor(.earthOrange)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.earthOrange.opacity(0.15))
                                .cornerRadius(20)
                        }
                    }
                }

                Spacer()

                VStack(spacing: 10) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(routeColor)
                            .font(.body)
                    }
                    if let onSave {
                        Button(action: onSave) {
                            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                                .foregroundColor(isSaved ? routeColor : .earthMuted)
                                .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaved)
                    }
                    if let onPost {
                        Button(action: onPost) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundColor(.earthMuted)
                                .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? routeColor.opacity(0.1) : Color.earthCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
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
                        .font(.headline).foregroundColor(.earthCream)
                    Text("by \(route.authorName)")
                        .font(.caption).foregroundColor(.earthMuted)
                }
                Spacer()
                DifficultyBadge(difficulty: route.difficulty, compact: true)
            }

            HStack(spacing: 16) {
                Label(route.distanceText, systemImage: "ruler")
                Label(route.timeText, systemImage: "clock")
                Label("\(route.estimatedSteps.formatted()) steps", systemImage: "figure.walk")
            }
            .font(.caption).foregroundColor(.earthMuted)

            HStack {
                Button(action: onWockett) {
                    HStack(spacing: 5) {
                        Image(systemName: hasVoted ? "w.circle.fill" : "w.circle")
                            .font(.system(size: 15, weight: .semibold))
                        Text(hasVoted
                             ? "\(route.wocketts) Wocketted!"
                             : "\(route.wocketts) Wockett\(route.wocketts == 1 ? "" : "s")")
                            .font(.subheadline.bold())
                    }
                    .foregroundColor(hasVoted ? .earthGreen : .earthMuted)
                    .animation(.spring(duration: 0.2), value: hasVoted)
                }
                .disabled(hasVoted)

                Spacer()

                if let onSave {
                    Button(action: onSave) {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .foregroundColor(isSaved ? .earthGreen : .earthMuted)
                            .font(.subheadline)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Color.earthCard)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.earthMuted.opacity(0.2), lineWidth: 1))
                    }
                    .disabled(isSaved)
                }

                Button(action: onStart) {
                    Label("Start Walk", systemImage: "figure.walk")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.earthGreen).foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
        }
        .padding(16)
        .background(Color.earthCard)
        .cornerRadius(14)
        .contextMenu {
            if let onHide {
                Button(role: .destructive) {
                    CommunityModerationStore.shared.report(route.id)
                    onHide()
                } label: {
                    Label("Report Route", systemImage: "flag")
                }
                Button(role: .destructive) {
                    CommunityModerationStore.shared.block(author: route.authorName)
                    onHide()
                } label: {
                    Label("Block \(route.authorName)", systemImage: "nosign")
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
                        statTile(value: route.distanceText, label: "Distance", icon: "ruler")
                        statTile(value: route.timeText,     label: "Time",     icon: "clock")
                        statTile(value: "~\(route.estimatedSteps.formatted())", label: "Steps", icon: "figure.walk")
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Route name")
                            .font(.caption).foregroundColor(.earthMuted)
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
                            .font(.caption).foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Button(action: post) {
                        Group {
                            if isPosting {
                                ProgressView().tint(.white)
                            } else if didPost {
                                Label("Shared!", systemImage: "checkmark.circle.fill")
                            } else {
                                Label("Post & Save to My Routes", systemImage: "square.and.arrow.up")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(didPost ? Color.earthGreen.opacity(0.6) : Color.earthGreen)
                        .foregroundColor(.white)
                        .font(.headline)
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
                errorMessage = "Sign into iCloud in Settings → [Your Name] to share routes."
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
                    errorMessage = "Sign into iCloud in Settings to share routes."
                case .networkUnavailable, .networkFailure:
                    errorMessage = "No internet connection. Try again when online."
                case .unknownItem, .invalidArguments:
                    errorMessage = "Schema not deployed. Open CloudKit Console → Deploy Schema to Production."
                case .permissionFailure:
                    errorMessage = "iCloud permission denied. Check app settings."
                default:
                    errorMessage = "Error \(ckError.code.rawValue): \(ckError.localizedDescription)"
                }
                isPosting = false
            } catch {
                errorMessage = "Couldn't share: \(error.localizedDescription)"
                isPosting = false
            }
        }
    }

    private func statTile(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(.earthGreen).font(.title3)
            Text(value).font(.headline.bold()).foregroundColor(.earthCream)
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
        .background(Color.earthCard).cornerRadius(14)
    }
}
