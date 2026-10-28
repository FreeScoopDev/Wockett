import Foundation

// MARK: - History search and filters (fix/history-search-filter, 2026-10-27)
//
// Activity History listed every stored activity with no way to find one, and
// its swipe-to-delete handed `WalkHistoryStore` offsets into the whole list.
// The list can now be narrowed by text, activity, period and pet, and once
// the rows on screen are a subset, an offset into them names a different
// activity in the store. So the screen deletes by id (`ids(at:in:)`, then
// `WalkHistoryStore.delete(ids:)`), and the header sums the same rows the
// list shows (`HistoryPage`), so the two cannot disagree.
//
// Nothing is left out by default: short, zero-distance and possibly-driven
// records all stay, as History has always shown them. The filter is view
// state only; nothing here writes to the store.

/// What the person has asked History to show. The defaults show everything.
/// `nonisolated` so `HistoryScope.apply` can read it off the main actor.
nonisolated struct HistoryFilter: Equatable {
    var query = ""
    /// nil = every activity.
    var activity: ActivityMode?
    var period: Period = .allTime
    /// nil = with or without any pet.
    var petID: UUID?

    enum Period: String, CaseIterable, Hashable {
        case allTime, thisWeek, thisMonth, last7Days

        var title: String {
            switch self {
            case .allTime:   return "All time"
            case .thisWeek:  return "This week"
            case .thisMonth: return "This month"
            case .last7Days: return "Last 7 days"
            }
        }
    }

    /// The search text as it is matched: trimmed, empty meaning no search.
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// How many of the filter menu's choices differ from their default. The
    /// search field shows its own text, so it is not counted here.
    var menuCount: Int {
        (activity == nil ? 0 : 1) + (period == .allTime ? 0 : 1) + (petID == nil ? 0 : 1)
    }

    /// Anything but the defaults, the search text included.
    var isActive: Bool { menuCount > 0 || !trimmedQuery.isEmpty }

    /// The filter menu's Reset: its own choices back to the defaults. The
    /// search text stays; Clear filters clears both.
    mutating func resetMenu() {
        activity = nil
        period = .allTime
        petID = nil
    }

    /// The header's title: "All activities", or the scope in force,
    /// "This month · Run · Nala · “river”". `petName` names `petID`.
    /// Main actor: `ActivityMode.displayName` is.
    @MainActor func scopeTitle(petName: String?) -> String {
        var parts: [String] = []
        if period != .allTime { parts.append(period.title) }
        if let activity { parts.append(activity.displayName) }
        if petID != nil { parts.append(petName ?? "One pet") }
        let text = trimmedQuery
        if !text.isEmpty { parts.append("“\(text)”") }
        return parts.isEmpty ? "All activities" : parts.joined(separator: " · ")
    }

    /// "No filters active", "1 filter active", "2 filters active".
    var accessibilityValue: String {
        switch menuCount {
        case 0: return "No filters active"
        case 1: return "1 filter active"
        default: return "\(menuCount) filters active"
        }
    }
}

enum HistoryScope {

    /// The sessions `filter` lets through, in the order given (the store's
    /// newest first). Every filter that is set must match.
    nonisolated static func apply(_ filter: HistoryFilter, to sessions: [WalkSession],
                                  now: Date, calendar: Calendar) -> [WalkSession] {
        let text = filter.trimmedQuery
        let window = interval(filter.period, now: now, calendar: calendar)
        return sessions.filter { session in
            if !text.isEmpty, !matches(session, text) { return false }
            if let activity = filter.activity,
               (ActivityMode(rawValue: session.activityType) ?? .walking) != activity { return false }
            if let window, !InsightsSummary.counts(session.date, in: window, now: now) { return false }
            if let petID = filter.petID, !PetStore.participated(petID, in: session) { return false }
            return true
        }
    }

    /// The shared week windows (`InsightsSummary`), or nil for all time.
    nonisolated static func interval(_ period: HistoryFilter.Period, now: Date,
                                     calendar: Calendar) -> DateInterval? {
        switch period {
        case .allTime:   return nil
        case .thisWeek:  return InsightsSummary.calendarWeek(containing: now, calendar: calendar)
        case .thisMonth: return InsightsSummary.interval(.month, containing: now, calendar: calendar)
        case .last7Days: return InsightsSummary.last7Days(now: now, calendar: calendar)
        }
    }

    /// The route name or the note contains `text`, ignoring case and accents.
    nonisolated private static func matches(_ session: WalkSession, _ text: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return session.routeName.range(of: text, options: options) != nil
            || session.notes.range(of: text, options: options) != nil
    }

    /// How many, how far and how long, summed over exactly `sessions`.
    nonisolated static func totals(_ sessions: [WalkSession]) -> (count: Int, meters: Double, seconds: TimeInterval) {
        (sessions.count,
         sessions.reduce(0) { $0 + $1.totalDistance },
         sessions.reduce(0) { $0 + $1.elapsedTime })
    }

    /// The ids of the rows at `offsets` in `visible`, the list the person
    /// swiped on. Offsets past its end are ignored.
    nonisolated static func ids(at offsets: IndexSet, in visible: [WalkSession]) -> Set<UUID> {
        Set(offsets.filter { visible.indices.contains($0) }.map { visible[$0].id })
    }
}

/// What History shows for one filter: the rows, and the header computed from
/// those rows and nothing else.
struct HistoryPage {
    enum State: Equatable {
        /// Nothing stored at all: the original empty state.
        case noHistory
        /// Something is stored, but the filter matches none of it.
        case noMatch
        case rows
    }

    let rows: [WalkSession]
    let totals: HistoryTotals
    /// How many of the rows fall in this calendar week.
    let thisWeek: Int
    let title: String
    let state: State

    init(filter: HistoryFilter, sessions: [WalkSession], petName: String?,
         now: Date, calendar: Calendar) {
        let rows = HistoryScope.apply(filter, to: sessions, now: now, calendar: calendar)
        self.rows = rows
        totals = HistoryTotals(sessions: rows)
        let week = InsightsSummary.calendarWeek(containing: now, calendar: calendar)
        thisWeek = rows.filter { InsightsSummary.counts($0.date, in: week, now: now) }.count
        title = filter.scopeTitle(petName: petName)
        state = sessions.isEmpty ? .noHistory : (rows.isEmpty ? .noMatch : .rows)
    }

    /// Swipe-to-delete on this page. `offsets` are into `rows`, the list on
    /// screen, so they are turned into ids against `rows`, never against
    /// `store.sessions`: once a filter is on, the same offset there is a
    /// different walk.
    func delete(_ offsets: IndexSet, from store: WalkHistoryStore) {
        store.delete(ids: HistoryScope.ids(at: offsets, in: rows))
    }
}
