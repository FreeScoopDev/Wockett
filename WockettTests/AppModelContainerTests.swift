import Testing
import SwiftData
@testable import PoCSquat

/// Under test the store must be local only. Tests run in the app, and a locally
/// signed app carries the iCloud entitlement, so any CloudKit setting other than
/// an explicit `.none` would sync test data to the simulator's iCloud account.
struct AppModelContainerTests {

    @Test("Under test, the store does not sync to CloudKit")
    func noCloudKitUnderTest() throws {
        #expect(AppModelContainer.isRunningUnderTests)
        let config = try #require(AppModelContainer.shared.configurations.first)
        #expect(config.cloudKitContainerIdentifier == nil,
                "store syncs to \(config.cloudKitContainerIdentifier ?? "")")
    }
}
