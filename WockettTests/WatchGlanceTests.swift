import Testing
import Foundation
import SwiftData
@testable import PoCSquat

/// The Apple Watch complications (feat/watch-complications): the snapshot
/// the phone builds, when it sends it, the one application context it
/// shares with the walk state, what the watch shows from it, and the
/// watch's stored copy. All pure or driven through a fake sink: nothing
/// touches WatchConnectivity.

private enum Fixture {
    static var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return cal
    }

    /// 2026-11-20 14:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_795_183_200)
    /// That day's 3 AM.
    static var dayStart: Date { StepManager.trackingDayStart(now: now, calendar: utc) }

    static func pet(_ name: String, steps: Int, goal: Int = 8_000) -> WatchGlancePet {
        WatchGlancePet(id: UUID(), name: name, emoji: "🐕", steps: steps, goal: goal)
    }

    static func snapshot(steps: Int? = 6_240, goal: Int = 10_000, pets: [WatchGlancePet] = [],
                         at time: Date = now) -> WatchGlanceSnapshot {
        .make(steps: steps, goal: goal, pets: pets,
              dayStart: StepManager.trackingDayStart(now: time, calendar: utc), now: time, calendar: utc)
    }

    static let onFace = WatchGlanceLinkStatus(canSend: true, complicationEnabled: true, remainingTransfers: 50)
    static let notOnFace = WatchGlanceLinkStatus(canSend: true, complicationEnabled: false, remainingTransfers: 0)
}

// MARK: - The snapshot

struct WatchGlanceSnapshotTests {
    @Test("A snapshot survives the trip to the watch unchanged")
    func roundTrip() throws {
        let original = Fixture.snapshot(pets: [Fixture.pet("Sample dog", steps: 4_100)])
        let message = WatchGlanceWire.payload(original)
        #expect(message.keys.sorted() == [WatchGlanceWire.key])
        #expect(WatchGlanceWire.decode(from: message) == original)
        #expect(WatchGlanceWire.decode(from: ["other": Data()]) == nil)
    }

    @Test("Pets are sorted by steps today, ties keep the phone's list order, and only three go")
    func petsSortedAndCapped() {
        let pets = [Fixture.pet("A", steps: 100), Fixture.pet("B", steps: 900), Fixture.pet("C", steps: 500),
                    Fixture.pet("D", steps: 900), Fixture.pet("E", steps: 50)]
        let snapshot = Fixture.snapshot(pets: pets)
        #expect(snapshot.pets.map(\.name) == ["B", "D", "C"])
    }

    @Test("The step day ends at the next 3 AM and the pets' day at the next midnight")
    func dayEnds() throws {
        let snapshot = Fixture.snapshot()
        let cal = Fixture.utc
        #expect(snapshot.day == "2026-11-20")
        #expect(snapshot.stepsUntil == cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 3)))
        #expect(snapshot.petsUntil == cal.date(from: DateComponents(year: 2026, month: 11, day: 21)))
        #expect(snapshot.madeAt == Fixture.now)
        // At 1 AM the step day is still yesterday's (it began at 3 AM then).
        let early = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 1)))
        let night = Fixture.snapshot(at: early)
        #expect(night.day == "2026-11-20")
        #expect(night.stepsUntil == cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 3)))
        #expect(night.petsUntil == cal.date(from: DateComponents(year: 2026, month: 11, day: 22)))
    }

    @Test("The same numbers made later are the same content; the newer one wins")
    func contentAndNewest() {
        let first = Fixture.snapshot()
        let later = Fixture.snapshot(at: Fixture.now.addingTimeInterval(60))
        #expect(first.sameContent(as: later))
        #expect(!first.sameContent(as: Fixture.snapshot(steps: 6_241)))
        #expect(WatchGlanceSnapshot.newest(first, later) == later)
        #expect(WatchGlanceSnapshot.newest(later, first) == later)
        #expect(WatchGlanceSnapshot.newest(nil, first) == first)
    }
}

// MARK: - When the phone sends

struct WatchGlanceSendPolicyTests {
    private func sent(_ snapshot: WatchGlanceSnapshot, status: WatchGlanceLinkStatus = Fixture.onFace,
                      at time: Date = Fixture.now) -> WatchGlanceSendPolicy {
        var policy = WatchGlanceSendPolicy()
        policy.didSend(snapshot, policy.decide(snapshot, now: time, status: status), at: time)
        return policy
    }

    @Test("The first snapshot goes in the context and, with a complication on the face, as a transfer")
    func firstSend() {
        let decision = WatchGlanceSendPolicy().decide(Fixture.snapshot(), now: Fixture.now, status: Fixture.onFace)
        #expect(decision == .init(context: true, complication: true))
    }

    @Test("Nothing is sent when the numbers have not changed")
    func unchanged() {
        let policy = sent(Fixture.snapshot())
        let later = Fixture.snapshot(at: Fixture.now.addingTimeInterval(3_600))
        #expect(policy.decide(later, now: later.madeAt, status: Fixture.onFace) == .none)
    }

    @Test("A step change inside 15 minutes goes in the context only; after 15 minutes as a transfer too")
    func fifteenMinuteThrottle() {
        let policy = sent(Fixture.snapshot(steps: 6_000))
        let soon = Fixture.now.addingTimeInterval(14 * 60 + 59)
        #expect(policy.decide(Fixture.snapshot(steps: 6_300, at: soon), now: soon, status: Fixture.onFace)
                == .init(context: true, complication: false))
        let due = Fixture.now.addingTimeInterval(15 * 60)
        #expect(policy.decide(Fixture.snapshot(steps: 6_300, at: due), now: due, status: Fixture.onFace)
                == .init(context: true, complication: true))
    }

    @Test("Reaching the goal goes at once, even inside the 15 minutes")
    func goalReachedAtOnce() {
        let policy = sent(Fixture.snapshot(steps: 9_900))
        let soon = Fixture.now.addingTimeInterval(60)
        #expect(policy.decide(Fixture.snapshot(steps: 10_050, at: soon), now: soon, status: Fixture.onFace).complication)
        // Past the goal already: more steps wait for the interval.
        let past = sent(Fixture.snapshot(steps: 10_050))
        #expect(!past.decide(Fixture.snapshot(steps: 10_500, at: soon), now: soon, status: Fixture.onFace).complication)
    }

    @Test("A changed goal and a new day go at once")
    func goalChangeAndNewDay() throws {
        let policy = sent(Fixture.snapshot())
        let soon = Fixture.now.addingTimeInterval(60)
        #expect(policy.decide(Fixture.snapshot(goal: 12_000, at: soon), now: soon, status: Fixture.onFace).complication)
        // 03:05 next day, five minutes after a send at 03:00 the day before's
        // step day ended: a new day.
        let cal = Fixture.utc
        let before = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 2, minute: 58)))
        let after = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 3, minute: 2)))
        let night = sent(Fixture.snapshot(steps: 7_000, at: before), at: before)
        #expect(night.decide(Fixture.snapshot(steps: 20, at: after), now: after, status: Fixture.onFace).complication)
    }

    @Test("No transfer without a complication on the face or with no budget left; nothing at all when the link is down")
    func noBudgetNoTransfer() {
        let snapshot = Fixture.snapshot()
        let policy = WatchGlanceSendPolicy()
        #expect(policy.decide(snapshot, now: Fixture.now, status: Fixture.notOnFace) == .init(context: true, complication: false))
        let spent = WatchGlanceLinkStatus(canSend: true, complicationEnabled: true, remainingTransfers: 0)
        #expect(policy.decide(snapshot, now: Fixture.now, status: spent) == .init(context: true, complication: false))
        #expect(policy.decide(snapshot, now: Fixture.now, status: .unavailable) == .none)
    }

    @Test("A held-back transfer is owed until the complication has the latest numbers")
    func behind() {
        var policy = sent(Fixture.snapshot(steps: 6_000))
        #expect(!policy.complicationBehind)
        let soon = Fixture.now.addingTimeInterval(60)
        let newer = Fixture.snapshot(steps: 6_300, at: soon)
        policy.didSend(newer, policy.decide(newer, now: soon, status: Fixture.onFace), at: soon)
        #expect(policy.complicationBehind)
        policy.forgetContext()
        #expect(!policy.complicationBehind)
    }
}

// MARK: - One application context for the walk state and the glance

struct WatchApplicationContextTests {
    @Test("Sending a glance keeps the walk state, and sending a walk state keeps the glance")
    func bothSurvive() {
        var state = WatchWalkState.idle(usesMiles: true)
        state.phase = .running
        state.startDate = Fixture.now
        let glance = Fixture.snapshot()

        var context = WatchApplicationContext()
        context.set(state)
        context.set(glance)
        #expect(WatchWire.decode(WatchWalkState.self, from: context.dictionary) == state)
        #expect(WatchGlanceWire.decode(from: context.dictionary) == glance)

        var next = state
        next.phase = .paused
        context.set(next)
        #expect(WatchWire.decode(WatchWalkState.self, from: context.dictionary) == next)
        #expect(WatchGlanceWire.decode(from: context.dictionary) == glance)
    }

    @Test("A context rebuilt from the last one sent keeps both keys and drops anything else")
    func seededFromLast() {
        var first = WatchApplicationContext()
        first.set(WatchWalkState.idle(usesMiles: false))
        first.set(Fixture.snapshot())
        var last = first.dictionary
        last["stray"] = "x"
        var rebuilt = WatchApplicationContext(last)
        #expect(Set(rebuilt.dictionary.keys) == [WatchWire.key, WatchGlanceWire.key])
        rebuilt.set(Fixture.snapshot(steps: 7_000))
        #expect(WatchWire.decode(WatchWalkState.self, from: rebuilt.dictionary) == .idle(usesMiles: false))
        #expect(WatchGlanceWire.decode(from: rebuilt.dictionary)?.steps == 7_000)
    }
}

// MARK: - The phone's context sender (WCSessionLink's merge)

@MainActor
struct WatchContextSenderTests {
    final class Session {
        var existing: [String: Any] = [:]
        var sent: [[String: Any]] = []
        var fails = false
        struct Failure: Error {}
        func update(_ context: [String: Any]) throws {
            if fails { throw Failure() }
            sent.append(context)
        }
    }

    private func sender(_ session: Session) -> WatchContextSender {
        WatchContextSender(seed: { session.existing }, update: { try session.update($0) })
    }

    @Test("State, then glance, then state: every update carries both keys, each the latest")
    func stateGlanceState() throws {
        let session = Session()
        let link = sender(session)
        var running = WatchWalkState.idle(usesMiles: false)
        running.phase = .running
        running.startDate = Fixture.now
        let glance = Fixture.snapshot()
        link.send(running)
        link.send(glance)
        var paused = running
        paused.phase = .paused
        link.send(paused)
        #expect(session.sent.count == 3)
        let last = try #require(session.sent.last)
        #expect(Set(last.keys) == [WatchWire.key, WatchGlanceWire.key])
        #expect(WatchWire.decode(WatchWalkState.self, from: last) == paused)
        #expect(WatchGlanceWire.decode(from: last) == glance)
        #expect(WatchWire.decode(WatchWalkState.self, from: session.sent[1]) == running)
    }

    @Test("The first send starts from the session's last context, so a relaunch keeps the glance")
    func seededFromSession() throws {
        let session = Session()
        session.existing = WatchGlanceWire.payload(Fixture.snapshot(steps: 7_000))
        sender(session).send(WatchWalkState.idle(usesMiles: true))
        let sent = try #require(session.sent.first)
        #expect(WatchGlanceWire.decode(from: sent)?.steps == 7_000)
        #expect(WatchWire.decode(WatchWalkState.self, from: sent) == .idle(usesMiles: true))
    }

    @Test("A send that throws (no watch app yet) still keeps the change for the next send")
    func throwingUpdateKeepsTheCache() throws {
        let session = Session()
        let link = sender(session)
        session.fails = true
        link.send(Fixture.snapshot(steps: 5_500))
        session.existing = [:]
        session.fails = false
        link.send(WatchWalkState.idle(usesMiles: false))
        let sent = try #require(session.sent.last)
        #expect(WatchGlanceWire.decode(from: sent)?.steps == 5_500)
        #expect(WatchWire.decode(WatchWalkState.self, from: sent) == .idle(usesMiles: false))
    }
}

// MARK: - The watch reading a context

struct WatchContextWalkStateTests {
    private func running(_ distance: Double) -> WatchWalkState {
        var state = WatchWalkState(mode: .walking, phase: .running, usesMiles: false)
        state.startDate = Date(timeIntervalSince1970: 1_000)
        state.distanceMeters = distance
        return state
    }

    @Test("A glance context repeating an older walk state does not step back or tap the marker again")
    func repeatedContextIsSkipped() throws {
        var filter = WatchContextWalkState()
        var display = WatchRemoteDisplay()
        var context = WatchApplicationContext()
        context.set(running(990))
        context.set(Fixture.snapshot(steps: 6_000))

        let fresh = filter.fresh(from: context.dictionary)
        let first = try #require(fresh)
        _ = display.receive(first)
        // A reply to a request for state, newer than the context.
        let taps = display.receive(reply: .state(running(1_010)), to: .requestState)
        #expect(taps == [.marker(1)])

        // The glance changes; the context carries the same, older walk state.
        context.set(Fixture.snapshot(steps: 6_100))
        let repeated = filter.fresh(from: context.dictionary)
        #expect(repeated == nil)
        #expect(display.state?.distanceMeters == 1_010)
        let next = display.receive(reply: .state(running(1_020)), to: .requestState)
        #expect(!next.contains(.marker(1)))

        // A new walk state in a context is shown.
        context.set(running(1_200))
        let newer = filter.fresh(from: context.dictionary)
        #expect(newer == running(1_200))
        let none = filter.fresh(from: [:])
        #expect(none == nil)
    }
}

// MARK: - What the watch shows

struct WatchGlanceDisplayTests {
    private let us = Locale(identifier: "en_US")

    @Test("Today's snapshot shows its steps; one from an earlier step day shows 0 with the goal kept")
    func staleDayShowsZero() {
        let snapshot = Fixture.snapshot(steps: 6_240)
        #expect(WatchGlanceDisplay.steps(snapshot, now: Fixture.now) == .steps(.init(steps: 6_240, goal: 10_000)))
        let justBefore = snapshot.stepsUntil.addingTimeInterval(-1)
        #expect(WatchGlanceDisplay.steps(snapshot, now: justBefore) == .steps(.init(steps: 6_240, goal: 10_000)))
        #expect(WatchGlanceDisplay.steps(snapshot, now: snapshot.stepsUntil) == .steps(.init(steps: 0, goal: 10_000)))
        #expect(WatchGlanceDisplay.steps(snapshot, now: snapshot.stepsUntil.addingTimeInterval(86_400 * 3))
                == .steps(.init(steps: 0, goal: 10_000)))
    }

    @Test("No snapshot yet, or a phone with no step count, shows the placeholder, not a false 0")
    func placeholder() {
        #expect(WatchGlanceDisplay.steps(nil, now: Fixture.now) == .placeholder)
        #expect(WatchGlanceDisplay.steps(Fixture.snapshot(steps: nil), now: Fixture.now) == .placeholder)
        #expect(WatchGlanceDisplay.pets(nil, now: Fixture.now) == .placeholder)
        #expect(WatchGlanceDisplay.placeholderText == "Open Wockett on your iPhone")
    }

    @Test("The rectangle draws the top two pets even when the snapshot carries three")
    func rectangleCapsAtTwo() {
        let pets = [Fixture.pet("Sample dog", steps: 4_100), Fixture.pet("Sample cat", steps: 1_250),
                    Fixture.pet("Sample rabbit", steps: 600)]
        let snapshot = Fixture.snapshot(pets: pets)
        #expect(snapshot.pets.count == 3)
        guard case .pets(let shown) = WatchGlanceDisplay.pets(snapshot, now: Fixture.now) else {
            Issue.record("expected pets")
            return
        }
        #expect(WatchGlanceDisplay.rectangularPets(shown).map(\.name) == ["Sample dog", "Sample cat"])
        #expect(WatchGlanceDisplay.rectangularPets(Array(pets.prefix(1))).count == 1)
    }

    @Test("Pets show their steps until midnight, then 0; no pets says how to add one")
    func pets() {
        let dog = Fixture.pet("Sample dog", steps: 4_100)
        let snapshot = Fixture.snapshot(pets: [dog])
        #expect(WatchGlanceDisplay.pets(snapshot, now: Fixture.now) == .pets([dog]))
        var reset = dog
        reset.steps = 0
        #expect(WatchGlanceDisplay.pets(snapshot, now: snapshot.petsUntil) == .pets([reset]))
        #expect(WatchGlanceDisplay.pets(Fixture.snapshot(pets: []), now: Fixture.now) == .noPets)
        #expect(WatchGlanceDisplay.noPetsText == "Add a pet in Wockett on your iPhone.")
    }

    @Test("The timeline has an entry now and at each day end still ahead")
    func entries() {
        let snapshot = Fixture.snapshot()
        #expect(WatchGlanceDisplay.entryDates(snapshot, now: Fixture.now)
                == [Fixture.now, snapshot.petsUntil, snapshot.stepsUntil])
        let afterMidnight = snapshot.petsUntil.addingTimeInterval(60)
        #expect(WatchGlanceDisplay.entryDates(snapshot, now: afterMidnight) == [afterMidnight, snapshot.stepsUntil])
        #expect(WatchGlanceDisplay.entryDates(nil, now: Fixture.now) == [Fixture.now])
    }

    @Test("The words: inline, the rectangle's progress line, percent and gauge fraction")
    func words() {
        let some = WatchGlanceDisplay.Steps(steps: 6_240, goal: 10_000)
        #expect(WatchGlanceDisplay.inline(some, locale: us) == "6,240 of 10,000 steps")
        #expect(WatchGlanceDisplay.progressLine(some, locale: us) == "62% of 10,000")
        #expect(some.fraction == 0.624)
        let done = WatchGlanceDisplay.Steps(steps: 12_400, goal: 10_000)
        #expect(WatchGlanceDisplay.inline(done, locale: us) == "12,400 steps, goal reached")
        #expect(WatchGlanceDisplay.progressLine(done, locale: us) == "Goal reached")
        #expect(done.fraction == 1)
        #expect(done.percent == 124)
        #expect(WatchGlanceDisplay.Steps(steps: 50, goal: 0).fraction == 0)
        #expect(WatchGlanceDisplay.compactCount(6_240, locale: us) == "6.2K")
    }

    @Test("The Start launcher's link is recognised, and nothing else is")
    func startLink() throws {
        let start = try #require(WatchWidgetLink.start)
        #expect(WatchWidgetLink.isStart(start))
        let other = try #require(URL(string: "wockett://walk"))
        #expect(!WatchWidgetLink.isStart(other))
    }
}

// MARK: - The watch's stored copy

struct WatchGlanceStorageTests {
    @Test("The watch keeps the newest snapshot and ignores an older one arriving late")
    func keepsNewest() throws {
        let suite = "wkt.tests.glance.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(WatchGlanceStorage.load(from: defaults) == nil)
        let older = Fixture.snapshot(steps: 5_000)
        let newer = Fixture.snapshot(steps: 6_000, at: Fixture.now.addingTimeInterval(60))
        #expect(WatchGlanceStorage.save(newer, to: defaults))
        #expect(!WatchGlanceStorage.save(older, to: defaults))
        #expect(!WatchGlanceStorage.save(newer, to: defaults))
        #expect(WatchGlanceStorage.load(from: defaults) == newer)
        #expect(!WatchGlanceStorage.save(newer, to: nil))
    }
}

// MARK: - The phone's builder and sender

@MainActor
struct WatchBridgeGlanceTests {
    final class FakeSink: WatchStateSink {
        var status = Fixture.onFace
        var glances: [(snapshot: WatchGlanceSnapshot, context: Bool, complication: Bool)] = []
        func send(_ state: WatchWalkState) {}
        func send(_ glance: WatchGlanceSnapshot, context: Bool, complication: Bool) {
            glances.append((glance, context, complication))
        }
        /// When set, the status reads as it is this many times, then
        /// becomes `afterReads`: the fake signals the change itself, so no
        /// test races a clock against main-actor queue time.
        var readsBeforeChange: Int?
        var afterReads = Fixture.onFace
        var glanceStatus: WatchGlanceLinkStatus {
            if let left = readsBeforeChange {
                if left <= 0 { status = afterReads; readsBeforeChange = nil } else { readsBeforeChange = left - 1 }
            }
            return status
        }
    }

    final class Clock {
        var now = Fixture.now
    }

    final class Box {
        var value: Int
        init(_ value: Int) { self.value = value }
    }

    private func bridge(steps: Int? = 6_240, goal: Int = 10_000,
                        pets: [WatchGlancePet] = []) throws -> (WatchBridge, FakeSink, Clock) {
        let config = ModelConfiguration(schema: AppModelContainer.schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppModelContainer.schema, configurations: config)
        let history = WalkHistoryStore(context: ModelContext(container))
        let clock = Clock()
        let bridge = WatchBridge(store: ActiveWalkStore(historyStore: history, isAppActive: { false }),
                                 canStart: { _ in false }, isAppActive: { false }, now: { clock.now }, startWait: 0)
        let sink = FakeSink()
        bridge.sink = sink
        bridge.glanceSource = WatchGlanceSource(steps: { steps }, goal: { goal }, pets: { pets })
        return (bridge, sink, clock)
    }

    @Test("Steps are what the widget snapshot holds, 0 once it is from before today's step day, nil with none")
    func steps() {
        let dayStart = Fixture.dayStart
        let fresh = WidgetSnapshot.Values(steps: 5_000, distanceMeters: 0, goal: 9_000, lastRefresh: dayStart)
        #expect(WatchBridge.glanceSteps(fresh, dayStart: dayStart) == 5_000)
        let old = WidgetSnapshot.Values(steps: 5_000, distanceMeters: 0, goal: 9_000,
                                        lastRefresh: dayStart.addingTimeInterval(-1))
        #expect(WatchBridge.glanceSteps(old, dayStart: dayStart) == 0)
        #expect(WatchBridge.glanceSteps(nil, dayStart: dayStart) == nil)
    }

    @Test("Pets go with id, name, emoji, today's steps from PetStore and goal: never the owner's contact")
    func petsFromStore() throws {
        let config = ModelConfiguration(schema: AppModelContainer.schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppModelContainer.schema, configurations: config)
        let store = PetStore(context: ModelContext(container))
        let dog = PetProfile(name: "Sample dog", goalSteps: 7_000, customEmoji: "🦮",
                             ownerName: "Owner Person", ownerPhone: "555-0100")
        let cat = PetProfile(name: "Sample cat", species: "Cat")
        let walk = WalkSession(id: UUID(), routeName: "Outing", date: Date(), elapsedTime: 1_800, totalDistance: 2_000,
                               waypoints: [], lapCount: 1, isLoop: false, activePetIds: [cat.id],
                               activityType: ActivityMode.walking.rawValue, petDistances: [cat.id: 800])
        let pets = WatchBridge.glancePets([dog, cat]) { store.todaySteps(for: $0, in: [walk]) }
        #expect(pets.map(\.name) == ["Sample dog", "Sample cat"])
        #expect(pets.map(\.emoji) == ["🦮", "🐈"])
        #expect(pets.map(\.goal) == [7_000, 10_000])
        #expect(pets[0].steps == 0)
        #expect(pets[1].steps == PetOutingRow.estimatedSteps(meters: 800))
        let json = try String(decoding: JSONEncoder().encode(pets), as: UTF8.self)
        #expect(!json.contains("Owner Person") && !json.contains("555-0100") && !json.contains("owner"))
    }

    @Test("The bridge sends the context and a transfer once, then nothing until the numbers change")
    func sendsOnChangeOnly() throws {
        let (bridge, sink, clock) = try bridge()
        bridge.refreshGlance()
        #expect(sink.glances.count == 1)
        #expect(sink.glances.first?.context == true && sink.glances.first?.complication == true)
        #expect(sink.glances.first?.snapshot.steps == 6_240)
        clock.now = clock.now.addingTimeInterval(30 * 60)
        bridge.refreshGlance()
        #expect(sink.glances.count == 1)
    }

    @Test("No glance without a source, or while the watch app is not installed or the link is down")
    func noSend() throws {
        let (bridge, sink, _) = try bridge()
        sink.status = .unavailable
        bridge.refreshGlance()
        #expect(sink.glances.isEmpty)
        sink.status = Fixture.onFace
        bridge.glanceSource = nil
        bridge.refreshGlance()
        #expect(sink.glances.isEmpty)
    }

    @Test("The background refresh returns at once when nothing can go: no watch, no app, or no session")
    func backgroundReturnsAtOnce() async throws {
        let (bridge, sink, _) = try bridge()
        sink.status = .unavailable
        let clock = ContinuousClock()
        let start = clock.now
        await bridge.sendGlanceFromBackground(timeout: .seconds(3))
        bridge.sink = nil
        await bridge.sendGlanceFromBackground(timeout: .seconds(3))
        #expect(clock.now - start < .seconds(3))  // the old wait took 6 s
        #expect(sink.glances.isEmpty)
    }

    @Test("The background refresh waits while the session is still activating, then sends")
    func backgroundWaitsForActivation() async throws {
        let (bridge, sink, _) = try bridge()
        sink.status = .activating
        sink.readsBeforeChange = 2
        // A long timeout: the loop ends on the fake's change, not the clock
        // (CLAUDE.md: no wall-clock guard under 5 minutes on main-actor tests).
        await bridge.sendGlanceFromBackground(timeout: .seconds(300))
        #expect(sink.glances.count == 1)
    }

    @Test("Once the complication left the face or the budget is spent, the 1 s check builds nothing")
    func checkBuildsNothingWhenNoTransferCanGo() throws {
        let steps = Box(6_000)
        let calls = Box(0)
        let (bridge, sink, clock) = try bridge()
        bridge.glanceSource = WatchGlanceSource(
            steps: { calls.value += 1; return steps.value },
            goal: { calls.value += 1; return 10_000 },
            pets: { calls.value += 1; return [] })
        bridge.refreshGlance()
        #expect(sink.glances.last?.complication == true)
        sink.status = Fixture.notOnFace
        clock.now = clock.now.addingTimeInterval(60)
        steps.value = 6_300
        bridge.refreshGlance()
        #expect(sink.glances.last?.context == true && sink.glances.last?.complication == false)
        clock.now = clock.now.addingTimeInterval(30 * 60)
        calls.value = 0
        for _ in 0..<20 { bridge.refreshGlanceIfBehind() }
        sink.status = WatchGlanceLinkStatus(canSend: true, complicationEnabled: true, remainingTransfers: 0)
        for _ in 0..<20 { bridge.refreshGlanceIfBehind() }
        #expect(calls.value == 0)
        #expect(sink.glances.count == 2)
    }

    @Test("A held-back transfer goes on the check once 15 minutes are up")
    func catchesUp() throws {
        let steps = Box(6_000)
        let (bridge, sink, clock) = try bridge()
        bridge.glanceSource = WatchGlanceSource(steps: { steps.value }, goal: { 10_000 }, pets: { [] })
        bridge.refreshGlance()
        clock.now = clock.now.addingTimeInterval(60)
        steps.value = 6_300
        bridge.refreshGlance()
        #expect(sink.glances.last?.context == true && sink.glances.last?.complication == false)
        bridge.refreshGlanceIfBehind()
        #expect(sink.glances.count == 2)
        clock.now = clock.now.addingTimeInterval(15 * 60)
        bridge.refreshGlanceIfBehind()
        #expect(sink.glances.count == 3)
        #expect(sink.glances.last?.context == false && sink.glances.last?.complication == true)
    }
}
