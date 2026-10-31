import HealthKit
import Observation

// MARK: - HealthExtrasAccess
//
// The Health tab's Recovery card and Walking health section read ten Health
// types nothing else in Wockett uses: sleep, heart rate, HRV, calories,
// floors and four gait measures. Until 2026-10-12 they were asked for in the
// first-launch Health sheet with steps and workouts, which made that sheet
// about sixteen switches long before the user had seen the Health tab.
// Now they are asked for from the Health tab itself, on a tap, behind a card
// that says what is read and why.
//
// Anyone who was asked already (every user of 1.15 and earlier, whatever
// they chose) gets `.unnecessary` from HealthKit and sees the tab as before.

@Observable
final class HealthExtrasAccess {
    static let shared = HealthExtrasAccess()
    /// The Health app, where access is changed once HealthKit has asked:
    /// Settings' Open Apple Health row and the empty trend's button.
    static let healthAppURL = URL(string: "x-apple-health://")

    enum State: Equatable {
        /// Not known yet; the tab shows neither the card nor the cards it gates.
        case checking
        /// Never asked: the tab shows the connect card.
        case needsAsk
        /// Asked before, or nothing to ask: the tab shows Recovery and gait.
        case ready
    }

    private(set) var state: State = .checking

    /// Exactly what the Recovery card and the Walking health section read.
    /// Adding a type to either list makes HealthKit report `.shouldRequest`
    /// for everyone, so every existing user sees the connect card again until
    /// they tap it. That is the right ask for a new type, but it is a visible
    /// change: say so in the changelog.
    static var readTypes: Set<HKObjectType> {
        RecoveryService.readTypes.union(GaitHealthService.readTypes.map { $0 as HKObjectType })
    }

    typealias StatusCheck = @Sendable (Set<HKObjectType>) async throws -> HKAuthorizationRequestStatus
    typealias Request = @Sendable (Set<HKObjectType>) async throws -> Void

    private let isAvailable: Bool
    private let status: StatusCheck
    private let request: Request

    init(isAvailable: Bool = HKHealthStore.isHealthDataAvailable() && !isWKTUITestMode,
         status: StatusCheck? = nil,
         request: Request? = nil) {
        self.isAvailable = isAvailable
        let store = HKHealthStore()
        self.status = status ?? { types in
            try await store.statusForAuthorizationRequest(toShare: [], read: types)
        }
        self.request = request ?? { types in
            try await store.requestAuthorization(toShare: [], read: types)
        }
    }

    /// Asks HealthKit whether these types were ever requested. Shows no UI.
    func refresh() async {
        guard isAvailable else { state = .ready; return }
        let result = try? await status(Self.readTypes)
        // Anything but a clear "never asked" keeps the tab as it was.
        state = result == .shouldRequest ? .needsAsk : .ready
    }

    /// The card's button: shows HealthKit's sheet for these types only.
    /// The tab shows the cards whatever the user chose: HealthKit never says
    /// whether reading was allowed, and a denied type simply reads as empty.
    func connect() async {
        if isAvailable { try? await request(Self.readTypes) }
        state = .ready
    }
}
