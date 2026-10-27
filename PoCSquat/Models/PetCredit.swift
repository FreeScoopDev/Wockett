import Foundation

// MARK: - Pet credit, as the pet screens show it
//
// Pets carry no pedometer. What Wockett knows about a pet's outing is the
// distance credited to it (`PetStore.walkedMeters`: the stretch it was on, or
// the whole outing for a walk saved before 1.7). Every pet "step" is that
// distance divided by 0.762 m, so the screens call it an estimate and say how
// it is made (2026-10-27, spec fix/pet-credit-labels). Until then the pet
// page's "Last 7 days" rows printed the whole outing's distance and the
// person's steps, beside totals that used the pet's credit, so a dog that
// joined halfway had rows that did not add up to its own total.

/// One row of a pet's "Last 7 days" list: the pet's credit for one outing.
struct PetOutingRow: Identifiable {
    /// A step estimate is distance over this stride, in metres.
    static let strideMeters = 0.762

    let session: WalkSession
    /// The distance credited to the pet (`PetStore.walkedMeters`).
    let creditedMeters: Double
    /// The whole outing's distance.
    let fullOutingMeters: Double

    var id: UUID { session.id }

    /// Nil when the pet was not on this outing (`PetStore.participated`).
    init?(petID: UUID, session: WalkSession) {
        guard PetStore.participated(petID, in: session) else { return nil }
        self.session = session
        creditedMeters = PetStore.walkedMeters(petID, in: session)
        fullOutingMeters = session.totalDistance
    }

    /// True when the pet's credit differs from the whole outing by more than
    /// a metre: it joined late or left early. A pet on the whole outing, and
    /// every walk saved before per-pet credit, shows one figure.
    var showsFullOuting: Bool { abs(fullOutingMeters - creditedMeters) > 1 }

    /// The pet's credited distance as steps: an estimate, never a count.
    var estimatedSteps: Int { Self.estimatedSteps(meters: creditedMeters) }

    static func estimatedSteps(meters: Double) -> Int {
        saturatingInt(meters / strideMeters)
    }

    /// The pet sheet's "Last 7 days" list: one row per outing in
    /// `PetStore.lastSevenDays`, newest first, every one of them, so the rows
    /// add up to the section's distance tile.
    static func lastSevenDays(_ petID: UUID, in sessions: [WalkSession],
                              now: Date, calendar: Calendar) -> [PetOutingRow] {
        PetStore.lastSevenDays(petID, in: sessions, now: now, calendar: calendar)
            .compactMap { PetOutingRow(petID: petID, session: $0) }
    }
}

/// The words the pet screens and Home use about pet credit. Pure, so the
/// tests check the exact strings.
enum PetCreditText {
    /// The My Pets switch's label (hidden on screen, spoken by VoiceOver).
    static func switchLabel(name: String) -> String {
        "Include \(name) on outings"
    }

    /// The My Pets switch's hint. The switch sets `isActiveOnWalk`, which an
    /// outing reads when it starts (`ActiveSessionView.startSession`,
    /// `StationaryWalkView.onAppear`). During an outing, credit starts and
    /// stops only from the outing screen's pet buttons (`togglePet`): turning
    /// a pet off here does not end its stretch, so the hint sends people there.
    /// Checked by reading the code on 2026-10-27; no test pins that behaviour,
    /// so if the My Pets switch ever starts or ends credit mid-outing, reword
    /// this hint.
    static let switchHint =
        "Pets switched on join an outing when it starts. During an outing, add or remove a pet on the outing screen."

    /// The visible line in a My Pets row, so the state is in words as well as
    /// the switch's colour.
    static func status(isActive: Bool) -> String {
        isActive ? "Joins your outings" : "Not joining"
    }

    /// The line under Home's Start button: "With Nala", "With Nala and Beef",
    /// "With Nala, Beef and Max". Nil with no active pet.
    static func companions(_ names: [String]) -> String? {
        guard let last = names.last else { return nil }
        guard names.count > 1 else { return "With \(last)" }
        return "With \(names.dropLast().joined(separator: ", ")) and \(last)"
    }

    /// Under the pet page's stat tiles.
    static func estimateCaption(name: String) -> String {
        let stride = PetOutingRow.strideMeters.formatted(.number.precision(.fractionLength(3)).locale(Locale(identifier: "en_US_POSIX")))
        return "Pets don't carry a step counter. Step estimates are distance credited to \(name) divided by \(stride) m."
    }

    /// A row's step line: "about 1,049 steps".
    static func aboutSteps(_ steps: Int) -> String {
        "about \(steps.formatted()) steps"
    }

    /// A pet's goal: "Goal: 8,000 est. steps".
    static func goal(_ steps: Int) -> String {
        "Goal: \(steps.formatted()) est. steps"
    }
}
