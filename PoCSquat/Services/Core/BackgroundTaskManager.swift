import BackgroundTasks
import HealthKit
import SwiftData

// MARK: - BackgroundTaskManager
//
// Registers and handles BGTaskScheduler tasks:
//   • healthkit-refresh  — updates today's step count (BGAppRefreshTask, fast)
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

    private func refreshStepCount() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let stepType = HKQuantityType(.stepCount)
        let cal      = Calendar.current
        var comps    = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 3
        let dayStart = cal.date(from: comps) ?? cal.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: dayStart, end: Date())

        let steps: Double = await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                cont.resume(returning: result?.sumQuantity()?.doubleValue(for: .count()) ?? 0)
            }
            healthStore.execute(q)
        }

        // Persist to UserDefaults so the widget can read it without launching the app
        UserDefaults(suiteName: "group.com.scoops.wockett")?.set(Int(steps), forKey: "bg_todaySteps")
        UserDefaults(suiteName: "group.com.scoops.wockett")?.set(Date(), forKey: "bg_lastRefresh")
    }
}
