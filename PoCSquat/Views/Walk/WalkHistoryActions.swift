import SwiftUI
import MapKit
import Combine

// MARK: - History actions (fix/history-actions, 2026-10-27)
//
// Until 2026-10-27 each Activity History row had two icon-only circles. The
// circular arrow called `ActiveWalkStore.beginSession` on the tap, so a stray
// touch began a walk, and the activity type could only be changed behind a
// note icon. A row now has one labelled More menu (Edit details, Repeat,
// Share), and Repeat shows what it would start before anything begins.

// MARK: - Header totals

/// The Activity History header: how many activities, how far and how long,
/// summed over exactly the sessions the list shows. It replaced lifetime
/// averages that mixed rides with zero-distance records and named no scope.
/// Nothing is left out: a short or zero-distance record counts like any other.
struct HistoryTotals: Equatable {
    let count: Int
    let meters: Double
    let seconds: TimeInterval

    /// `sessions` is the visible rows (`HistoryPage`), filtered or not.
    init(sessions: [WalkSession]) {
        (count, meters, seconds) = HistoryScope.totals(sessions)
    }

    /// "1 activity", "12 activities".
    var countText: String { count == 1 ? "1 activity" : "\(count) activities" }

    func distanceText(formatter: MKDistanceFormatter = .abbreviated) -> String {
        formatter.string(fromDistance: meters)
    }

    /// "45m", "6h 10m": whole minutes, as the old averages showed them.
    var timeText: String {
        let minutes = max(0, Int(seconds)) / 60
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// "12 activities · 18.4 mi · 6h 10m".
    func summary(formatter: MKDistanceFormatter = .abbreviated) -> String {
        "\(countText) · \(distanceText(formatter: formatter)) · \(timeText)"
    }
}

// MARK: - Repeat review

/// What Repeat would start, read before anything begins. Built from the row's
/// session and the pets on the walk now (`PetStore.activePets`), the pets that
/// get credit once the walk screen opens.
struct RepeatReview: Equatable {
    /// "Repeat this hike", "Repeat this ride".
    let title: String
    /// What Start begins: "Walk", "Run", "Ride". A hike repeats as a walk.
    let activity: String
    let routeName: String
    /// The repeated activity's own distance and time, as its row shows them.
    let distance: String
    let duration: String
    /// "No pets", "Nala", "Nala and Beef", "Nala, Beef and Miso".
    let companions: String
    /// Said under the details when what starts is not quite what was done.
    let note: String?
    /// Why this one cannot be repeated from History; nil when it can.
    let unavailableReason: String?

    var canStart: Bool { unavailableReason == nil }

    init(session: WalkSession, activePets: [PetProfile],
         distanceFormatter: MKDistanceFormatter = .abbreviated) {
        let wording = session.wording
        // `toNavigableRoute()` carries the activity type and never `isHike`:
        // only a trail's own Start makes a hike.
        let mode = wording.activityMode
        title = "Repeat this \(wording.noun)"
        activity = mode.displayName
        routeName = session.routeName
        distance = distanceFormatter.string(fromDistance: session.totalDistance)
        duration = session.timeText
        companions = Self.names(activePets.map(\.name))
        note = wording.isHike ? "Starts as a walk on the same route. A hike starts from its trail." : nil
        unavailableReason = Self.unavailableReason(for: session)
    }

    /// Why `session` cannot be repeated from History; nil when it can.
    ///
    /// Repeat starts `session.toNavigableRoute()`, which carries the saved
    /// waypoints as the route. With none, the walk screen treats it as a free
    /// walk that already exists (`ActiveSessionView.startSession` starts only
    /// guided sessions), so nothing ever records: a timer stuck at 0:00. So a
    /// session needs at least one waypoint, which is exactly the walk
    /// screen's `isGuided`. That leaves out manually logged Past Walks,
    /// Untracked Walks, free walks that got no GPS fix and pet-credit
    /// entries, all saved with `waypoints: []`. Indoor is checked first: it
    /// has no waypoints either, but it starts from Home (Indoor, then Start).
    static func unavailableReason(for session: WalkSession) -> String? {
        if session.wording.activityMode == .stationary {
            return "Indoor walks have no route to follow. Start one from Home: choose Indoor, then Start Indoor."
        }
        if session.waypoints.isEmpty {
            return "This \(session.wording.noun) has no route to follow, so it can't be repeated. "
                + "Start a new one from Home."
        }
        return nil
    }

    static func names(_ names: [String]) -> String {
        switch names.count {
        case 0: return "No pets"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }
}

/// The review sheet's one decision. Only `start()` calls `begin`, at most
/// once however often Start is tapped; nothing calls it on appear, Cancel or
/// a swipe down. `begin` is false when a walk is already in progress (the
/// store's `beginSession` returned nil): then the existing alert shows and
/// the sheet stays up, because nothing started.
@MainActor
final class RepeatReviewController: ObservableObject {
    enum Outcome: Equatable { case started, alreadyActive, unavailable }

    let review: RepeatReview
    @Published var showAlreadyActive = false
    @Published private(set) var started = false
    private let begin: () -> Bool

    init(review: RepeatReview, begin: @escaping () -> Bool) {
        self.review = review
        self.begin = begin
    }

    @discardableResult
    func start() -> Outcome {
        guard review.canStart else { return .unavailable }
        guard !started else { return .started }
        if begin() {
            started = true
            return .started
        }
        showAlreadyActive = true
        return .alreadyActive
    }
}

struct RepeatReviewSheet: View {
    @StateObject private var controller: RepeatReviewController
    /// Called once the walk has begun; the sheet then closes itself.
    let onStarted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(review: RepeatReview, begin: @escaping () -> Bool, onStarted: @escaping () -> Void) {
        _controller = StateObject(wrappedValue: RepeatReviewController(review: review, begin: begin))
        self.onStarted = onStarted
    }

    private var review: RepeatReview { controller.review }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                        VStack(spacing: 0) {
                            detailRow("Activity", review.activity)
                            WktDivider()
                            detailRow("Route", review.routeName)
                            WktDivider()
                            detailRow("Distance", review.distance)
                            WktDivider()
                            detailRow("Time", review.duration)
                            if review.canStart {
                                WktDivider()
                                detailRow("Pets getting credit", review.companions)
                            }
                        }
                        .wktCard(padding: 14)

                        if let note = review.note {
                            Text(note).font(.wktLabel).foregroundColor(.earthMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let reason = review.unavailableReason {
                            Text(reason).font(.wktBodyText).foregroundColor(.earthCream)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("history.repeat.reason")
                        }

                        VStack(spacing: WktSpacing.betweenCards) {
                            if review.canStart {
                                WktPrimaryButton(title: "Start") {
                                    if controller.start() == .started {
                                        onStarted()
                                        dismiss()
                                    }
                                }
                                .accessibilityIdentifier("history.repeat.start")
                            }
                            WktSecondaryButton(title: "Cancel") { dismiss() }
                        }
                    }
                    .padding(.horizontal, WktSpacing.screen)
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle(review.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .walkAlreadyActiveAlert(isPresented: $controller.showAlreadyActive)
        // At the accessibility sizes the medium height left Start half below
        // the screen on an iPhone 17e and Cancel off it, so those open at
        // .large, as the finish sheet does. Default sizes are unchanged.
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.wktLabel).foregroundColor(.earthMuted)
            Spacer(minLength: 8)
            Text(value).font(.wktBodyText).foregroundColor(.earthCream)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Walk already active

extension View {
    /// The alert Repeat has always shown when a walk is already in progress.
    /// It sits on whatever is presented on top (the review sheet), since an
    /// alert on the screen beneath a sheet never appears.
    func walkAlreadyActiveAlert(isPresented: Binding<Bool>) -> some View {
        alert("Walk Already Active", isPresented: isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You have a walk in progress. Return to the home screen to resume or end it first.")
        }
    }
}
