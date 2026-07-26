import Foundation
import HealthKit
import CoreLocation

// Wraps HKWorkoutBuilder + HKWorkoutRouteBuilder for a single workout session.
// Silently no-ops if HealthKit write authorization is not granted, so it is
// safe to create unconditionally regardless of the user's tracking mode.
final class HealthWorkoutWriter {

    private let healthStore   = HKHealthStore()
    private var builder:       HKWorkoutBuilder?
    private var routeBuilder:  HKWorkoutRouteBuilder?

    let activityType: HKWorkoutActivityType
    let isIndoor: Bool
    private var startDate: Date?

    init(activityType: HKWorkoutActivityType, isIndoor: Bool = false) {
        self.activityType = activityType
        self.isIndoor = isIndoor
    }

    // MARK: - Lifecycle

    func start(at date: Date) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard healthStore.authorizationStatus(for: .workoutType()) == .sharingAuthorized else { return }

        startDate = date

        let config = HKWorkoutConfiguration()
        config.activityType = activityType
        config.locationType = isIndoor ? .indoor : .outdoor

        let workoutBuilder = HKWorkoutBuilder(
            healthStore: healthStore,
            configuration: config,
            device: .local()
        )
        self.builder = workoutBuilder
        self.routeBuilder = workoutBuilder.seriesBuilder(for: HKSeriesType.workoutRoute()) as? HKWorkoutRouteBuilder

        try? await workoutBuilder.beginCollection(at: date)
    }

    // Feed location updates in real-time for the GPS route.
    // Safe to call frequently — filters out low-accuracy fixes automatically.
    func addLocations(_ locations: [CLLocation]) {
        let accurate = locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy <= 50 }
        guard let routeBuilder, !accurate.isEmpty else { return }
        routeBuilder.insertRouteData(accurate) { _, _ in }
    }

    // Finishes the workout and attaches the GPS route.
    // Returns the saved HKWorkout on success, nil if HealthKit wasn't available.
    @discardableResult
    func finish(totalDistanceMeters: Double, endDate: Date) async -> HKWorkout? {
        guard let builder, let startDate else { return nil }

        let distanceType: HKQuantityType = activityType == .cycling
            ? HKQuantityType(.distanceCycling)
            : HKQuantityType(.distanceWalkingRunning)

        let distanceSample = HKQuantitySample(
            type: distanceType,
            quantity: HKQuantity(unit: .meter(), doubleValue: max(totalDistanceMeters, 0)),
            start: startDate, end: endDate
        )

        // Rough calorie estimate without user weight:
        // walking ≈ 60 kcal/km (MET ~3.5), cycling ≈ 35 kcal/km (MET ~7.5 but lower body weight load)
        let kcalPerKm: Double = activityType == .cycling ? 35 : 60
        let kcal = max(1, (totalDistanceMeters / 1_000) * kcalPerKm)
        let calSample = HKQuantitySample(
            type: HKQuantityType(.activeEnergyBurned),
            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
            start: startDate, end: endDate
        )

        try? await builder.addSamples([distanceSample, calSample])
        try? await builder.endCollection(at: endDate)

        guard let workout = try? await builder.finishWorkout() else { return nil }
        try? await routeBuilder?.finishRoute(with: workout, metadata: nil)
        return workout
    }
}
