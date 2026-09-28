import BackgroundTasks
import HealthKit
import SwiftData

// MARK: - BackgroundTaskManager
//
// Registers and handles BGTaskScheduler tasks:
//   • healthkit-refresh  — updates today's step count and looks for a walk the
//                          user did without tracking (BGAppRefreshTask, fast)
//   • cloudkit-sync      — CloudKit reconciliation after a walk finishes (BGProcessingTask, longer-running)
//
// Both tasks are triggered by the system opportunistically. The app schedules
// the next run at the end of each task handler (rolling schedule).

final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()

    private let healthKitTaskID = "com.scoops.wockett.healthkit-refresh"
    private let cloudKitTaskID  = "com.scoops.wockett.cloudkit-sync"

    private let healthStore = HKHealthStore()

    private init() {}

    // MARK: - Registration (call once at app launch)

    func registerTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: healthKitTaskID, using: nil) { [weak self] task in
            guard let self, let task = task as? BGAppRefreshTask else { return }
            self.handleHealthKitRefresh(task: task)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: cloudKitTaskID, using: nil) { [weak self] task in
            guard let self, let task = task as? BGProcessingTask else { return }
            self.handleCloudKitSync(task: task)
        }
        // Start the rolling schedule. Each handler submits the next request, but
        // nothing submitted the first one, so the refresh task had no way to ever
        // run. Submitting an identifier that already has a pending request just
        // replaces it, so doing this at every launch is safe.
        scheduleHealthKitRefresh()
    }

    // MARK: - Scheduling

    func scheduleHealthKitRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: healthKitTaskID)
        // Ask to be woken within the next hour; system decides exact timing
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    func scheduleCloudKitSync() {
        let request = BGProcessingTaskRequest(identifier: cloudKitTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 300)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Task handlers

    private func handleHealthKitRefresh(task: BGAppRefreshTask) {
        scheduleHealthKitRefresh()

        let fetchTask = Task {
            await refreshStepCount()
            await UntrackedWalkDetector.shared.check()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            fetchTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    private func handleCloudKitSync(task: BGProcessingTask) {
        scheduleCloudKitSync()

        let syncTask = Task {
            // SwiftData + CloudKit handles sync automatically when the container
            // is configured with cloudKitDatabase. Triggering a save on the
            // background context is enough to push pending changes.
            let context = ModelContext(AppModelContainer.shared)
            try? context.save()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            syncTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    // MARK: - HealthKit step refresh

    /// Today's steps and distance, written where the widget reads them.
    /// Until 1.14 this wrote `bg_todaySteps`, which nothing read, so the
    /// widget only changed when the app was opened.
    private func refreshStepCount() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        // The same 3 AM-to-now day the Home ring and the Siri answer use.
        let predicate = HKQuery.predicateForSamples(withStart: StepManager.trackingDayStart(), end: Date())

        async let steps    = todaySum(HKQuantityType(.stepCount),              unit: .count(), predicate: predicate)
        async let distance = todaySum(HKQuantityType(.distanceWalkingRunning), unit: .meter(), predicate: predicate)
        let (s, d) = await (steps, distance)
        WidgetSnapshot.write(steps: Int(s), distanceMeters: d)
    }

    private func todaySum(_ type: HKQuantityType, unit: HKUnit, predicate: NSPredicate) async -> Double {
        await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                      options: .cumulativeSum) { _, result, _ in
                cont.resume(returning: result?.sumQuantity()?.doubleValue(for: unit) ?? 0)
            }
            healthStore.execute(q)
        }
    }
}
