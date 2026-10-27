import Testing
import Foundation
import SwiftData
@testable import PoCSquat

/// A pet's page shows the pet's own credit, and its "steps" are estimates
/// (2026-10-27, spec fix/pet-credit-labels). Every expected number below is
/// worked out by hand from the fixture (metres / 0.762, truncated), never
/// computed by the code under test.
@MainActor
struct PetCreditLabelsTests {

    private let nala = UUID()
    private let beef = UUID()

    private static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.firstWeekday = 1
        return cal
    }()

    private func at(_ day: Int, _ hour: Int) throws -> Date {
        try #require(Self.utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour)))
    }

    private func outing(at date: Date = Date(timeIntervalSince1970: 1_800_000_000),
                        total: Double, active: [UUID], credit: [UUID: Double],
                        mode: ActivityMode = .walking) -> WalkSession {
        WalkSession(id: UUID(), routeName: "Outing", date: date, elapsedTime: 1_800, totalDistance: total,
                    waypoints: [], lapCount: 1, isLoop: false, activePetIds: active,
                    activityType: mode.rawValue, petDistances: credit)
    }

    // MARK: Row model

    @Test("A dog that joined for 800 m of a 2,000 m outing: credited 800, full 2,000, about 1,049 steps")
    func joinedHalfway() throws {
        let walk = outing(total: 2_000, active: [nala], credit: [nala: 800])
        let row = try #require(PetOutingRow(petID: nala, session: walk))
        #expect(row.creditedMeters == 800)
        #expect(row.fullOutingMeters == 2_000)
        #expect(row.showsFullOuting)
        #expect(row.estimatedSteps == 1_049)     // 800 / 0.762 = 1,049.87
    }

    @Test("A walk saved before per-pet credit credits the whole distance and shows one figure")
    func legacyFallback() throws {
        let walk = outing(total: 2_000, active: [nala], credit: [:])
        let row = try #require(PetOutingRow(petID: nala, session: walk))
        #expect(row.creditedMeters == 2_000)
        #expect(!row.showsFullOuting)
        #expect(row.estimatedSteps == 2_624)     // 2,000 / 0.762 = 2,624.67
    }

    @Test("A pet not on the outing has no row, with per-pet credit or without")
    func absentPetIsNotARow() {
        #expect(PetOutingRow(petID: nala, session: outing(total: 2_000, active: [beef], credit: [beef: 2_000])) == nil)
        #expect(PetOutingRow(petID: nala, session: outing(total: 2_000, active: [beef], credit: [:])) == nil)
    }

    @Test("A pet credited the whole outing, or within a metre of it, shows no 'full outing' line")
    func wholeOutingShowsOneFigure() throws {
        let whole = try #require(PetOutingRow(petID: nala, session: outing(total: 2_000, active: [nala], credit: [nala: 2_000])))
        #expect(!whole.showsFullOuting)
        let nearly = try #require(PetOutingRow(petID: nala, session: outing(total: 2_000, active: [nala], credit: [nala: 1_999.5])))
        #expect(!nearly.showsFullOuting)
        let short = try #require(PetOutingRow(petID: nala, session: outing(total: 2_000, active: [nala], credit: [nala: 1_998])))
        #expect(short.showsFullOuting)
    }

    // MARK: The week, through the functions the pet sheet calls

    /// Friday 30 Oct 2026, 18:00 UTC. Inside the last 7 days: Nala's 800 m of a
    /// 2,000 m walk (Mon 26), a pre-1.7 walk of 1,500 m (Tue 27), a 1,200 m walk
    /// she did all of (Wed 28), Beef's walk without her (Thu 29), and her 5,000 m
    /// of a ride (Fri 30). Outside: a walk on Thu 22. Credit: 800 + 1,500 +
    /// 1,200 + 5,000 = 8,500 m. Estimates: 1,049 + 1,968 + 1,574 + 6,561 = 11,152.
    @Test("The rows' credit adds up to the Distance tile; the Est. steps tile totals every row, rides included")
    func rowsAddUpToTheTiles() throws {
        let now = try at(30, 18)
        let sessions = try [
            outing(at: at(22, 9), total: 3_000, active: [nala], credit: [nala: 3_000]),
            outing(at: at(26, 9), total: 2_000, active: [nala, beef], credit: [nala: 800, beef: 2_000]),
            outing(at: at(27, 9), total: 1_500, active: [nala], credit: [:]),
            outing(at: at(28, 9), total: 1_200, active: [nala], credit: [nala: 1_200]),
            outing(at: at(29, 9), total: 4_000, active: [beef], credit: [beef: 4_000]),
            outing(at: at(30, 9), total: 9_000, active: [nala], credit: [nala: 5_000], mode: .cycling)
        ]
        let rows = PetOutingRow.lastSevenDays(nala, in: sessions, now: now, calendar: Self.utc)
        #expect(rows.map(\.creditedMeters) == [5_000, 1_200, 1_500, 800])   // newest first
        #expect(rows.map(\.showsFullOuting) == [true, false, false, true])
        #expect(rows.reduce(0) { $0 + $1.creditedMeters } == 8_500)

        let store = try inMemoryPetStore()
        let pet = PetProfile(id: nala, name: "Nala")
        #expect(store.weeklyDistance(for: pet, in: sessions, now: now, calendar: Self.utc) == 8_500)
        #expect(store.weeklySteps(for: pet, in: sessions, now: now, calendar: Self.utc) == 11_152)
    }

    private func inMemoryPetStore() throws -> PetStore {
        let config = ModelConfiguration(schema: AppModelContainer.schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppModelContainer.schema, configurations: config)
        return PetStore(context: ModelContext(container))
    }

    // MARK: Words

    @Test("The My Pets switch is named for the pet, and its hint says where credit changes mid-outing")
    func switchWords() {
        #expect(PetCreditText.switchLabel(name: "Nala") == "Include Nala on outings")
        #expect(PetCreditText.switchLabel(name: "Sir Reginald Fluffington the Third")
                == "Include Sir Reginald Fluffington the Third on outings")
        #expect(PetCreditText.switchHint
                == "Pets switched on join an outing when it starts. During an outing, add or remove a pet on the outing screen.")
        #expect(PetCreditText.status(isActive: true) == "Joins your outings")
        #expect(PetCreditText.status(isActive: false) == "Not joining")
    }

    @Test("Home's line names one, two or three pets, and is absent with none")
    func companionsLine() {
        #expect(PetCreditText.companions([]) == nil)
        #expect(PetCreditText.companions(["Nala"]) == "With Nala")
        #expect(PetCreditText.companions(["Nala", "Beef"]) == "With Nala and Beef")
        #expect(PetCreditText.companions(["Nala", "Beef", "Max"]) == "With Nala, Beef and Max")
        #expect(PetCreditText.companions(["Sir Reginald Fluffington the Third"])
                == "With Sir Reginald Fluffington the Third")
    }

    @Test("The caption says how a pet's step estimate is made")
    func estimateCaption() {
        #expect(PetCreditText.estimateCaption(name: "Nala")
                == "Pets don't carry a step counter. Step estimates are distance credited to Nala divided by 0.762 m.")
    }
}
