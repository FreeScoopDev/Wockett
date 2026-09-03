import SwiftData
import Foundation

// MARK: - AppModelContainer
//
// Single source of truth for the SwiftData model container.
// Three-tier fallback so the app never crashes at launch:
//   1. CloudKit-backed persistent store (primary)
//   2. Local persistent store (simulator / no iCloud sign-in)
//   3. Wipe corrupted store + recreate (schema mismatch from dev iteration)
//   4. In-memory only (data is ephemeral but app stays alive)

enum AppModelContainer {

    // True when the process is running under XCTest — unit tests inject into the
    // host app (XCTestConfigurationFilePath is set), UI tests pass -WKTUITest.
    //
    // CloudKit mirroring is skipped in that case. CI builds with
    // CODE_SIGNING_ALLOWED=NO carry no iCloud entitlement, and CoreData's
    // CloudKit setup runs asynchronously on com.apple.coredata.cloudkit.queue
    // and TRAPS rather than throwing — so the `try?` fallbacks below cannot
    // catch it and the app dies ~3s after launch. Tests should not sync to a
    // real iCloud database anyway.
    static var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.arguments.contains("-WKTUITest")
    }

    static let schema = Schema([
        WalkSessionRecord.self,
        PetProfileRecord.self,
        CustomRouteRecord.self,
        BookmarkedLocationRecord.self
    ])

    static let shared: ModelContainer = {
        // Attempt 1: CloudKit-backed persistent store (skipped under tests)
        if !isRunningUnderTests {
            let cloudConfig = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private("iCloud.Scoops.PoCSquat")
            )
            if let container = try? ModelContainer(for: schema, configurations: cloudConfig) {
                runMigrationIfNeeded(context: ModelContext(container))
                return container
            }
        }

        // Attempt 2: Local persistent store (no CloudKit)
        let localConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        if let container = try? ModelContainer(for: schema, configurations: localConfig) {
            runMigrationIfNeeded(context: ModelContext(container))
            return container
        }

        // Attempt 3: Wipe corrupted / schema-mismatched store and recreate
        wipeDefaultStore()
        if let container = try? ModelContainer(for: schema, configurations: localConfig) {
            return container
        }

        // Final fallback: in-memory (data is ephemeral this session, but no crash)
        let memConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: memConfig)
    }()

    // MARK: - One-time legacy migration

    private static let migrationDoneKey = "wkt_swiftDataMigration_v1"

    private static func runMigrationIfNeeded(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: migrationDoneKey) else { return }

        migrateWalkSessions(into: context)
        migratePets(into: context)
        migrateCustomRoutes(into: context)
        migrateBookmarks(into: context)

        try? context.save()
        UserDefaults.standard.set(true, forKey: migrationDoneKey)
    }

    // Walk sessions from JSON file at applicationSupportDirectory/walkHistory.json
    private static func migrateWalkSessions(into context: ModelContext) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("walkHistory.json")
        guard let data = try? Data(contentsOf: url),
              let sessions = try? JSONDecoder().decode([WalkSession].self, from: data) else {
            guard let data = UserDefaults.standard.data(forKey: "walkHistory_v1"),
                  let sessions = try? JSONDecoder().decode([WalkSession].self, from: data) else { return }
            sessions.forEach { context.insert(WalkSessionRecord(from: $0)) }
            UserDefaults.standard.removeObject(forKey: "walkHistory_v1")
            return
        }
        sessions.forEach { context.insert(WalkSessionRecord(from: $0)) }
        try? FileManager.default.removeItem(at: url)
    }

    private static func migratePets(into context: ModelContext) {
        guard let data = UserDefaults.standard.data(forKey: "petProfiles_v2"),
              let pets = try? JSONDecoder().decode([PetProfile].self, from: data) else { return }
        pets.forEach { context.insert(PetProfileRecord(from: $0)) }
        UserDefaults.standard.removeObject(forKey: "petProfiles_v2")
    }

    private static func migrateCustomRoutes(into context: ModelContext) {
        guard let data = UserDefaults.standard.data(forKey: "customRoutes_v1"),
              let routes = try? JSONDecoder().decode([CustomRoute].self, from: data) else { return }
        routes.forEach { context.insert(CustomRouteRecord(from: $0)) }
        UserDefaults.standard.removeObject(forKey: "customRoutes_v1")
    }

    private static func migrateBookmarks(into context: ModelContext) {
        guard let data = UserDefaults.standard.data(forKey: "bookmarkedLocations_v1"),
              let locations = try? JSONDecoder().decode([BookmarkedLocation].self, from: data) else { return }
        locations.forEach { context.insert(BookmarkedLocationRecord(from: $0)) }
        UserDefaults.standard.removeObject(forKey: "bookmarkedLocations_v1")
    }

    // Removes a corrupted or schema-mismatched SQLite store so the next attempt starts clean.
    private static func wipeDefaultStore() {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: support.appendingPathComponent("default.store\(suffix)"))
        }
    }
}
