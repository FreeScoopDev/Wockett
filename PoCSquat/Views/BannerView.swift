import SwiftUI

// MARK: - Banner Store

@Observable
final class BannerStore {
    static let shared = BannerStore()

    var userAffirmations: [String] = []
    private(set) var displayTitle: String = "Wockett"
    private(set) var displayOpacity: Double = 1.0

    private let udKey = "bannerAffirmations_v1"
    private var cycleTask: Task<Void, Never>?

    init() {
        load()
        cycleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cycle()
        }
    }

    deinit { cycleTask?.cancel() }

    var allQuotes: [String] { curatedQuotes + userAffirmations }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        userAffirmations.append(t)
        save()
    }

    func delete(at offsets: IndexSet) {
        userAffirmations.remove(atOffsets: offsets)
        save()
    }

    private func save() { UserDefaults.standard.set(userAffirmations, forKey: udKey) }
    private func load() { userAffirmations = UserDefaults.standard.stringArray(forKey: udKey) ?? [] }

    @MainActor
    private func cycle() async {
        var shuffled = allQuotes.shuffled()
        var phase = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { break }
            withAnimation(.easeOut(duration: 0.3)) { displayOpacity = 0 }
            try? await Task.sleep(nanoseconds: 320_000_000)
            phase += 1
            let total = shuffled.count + 1   // +1 slot for "Wockett"
            if phase % total == 0 {
                shuffled = allQuotes.shuffled()
                displayTitle = "Wockett"
            } else {
                displayTitle = shuffled[(phase % total) - 1]
            }
            withAnimation(.easeIn(duration: 0.3)) { displayOpacity = 1 }
        }
    }
}

// MARK: - Rotating Banner Title

struct BannerTitleView: View {
    var store: BannerStore = .shared

    var body: some View {
        Group {
            if store.displayTitle == "Wockett" {
                Text("Wockett")
                    .font(.wktDisplay(17))
                    .foregroundColor(.earthCream)
            } else {
                Text(store.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .italic()
                    .foregroundColor(.earthMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 220)
                    .minimumScaleFactor(0.8)
            }
        }
        .opacity(store.displayOpacity)
    }
}

// MARK: - Curated Quotes

private let curatedQuotes: [String] = [
    "Every step forward matters.",
    "Movement is medicine.",
    "Your best walk is still ahead.",
    "Progress over perfection.",
    "Walk like nobody's watching.",
    "Small steps, big distances.",
    "One step at a time.",
    "You don't have to go fast. Just go.",
    "Show up. That's step one.",
    "Consistent beats intense.",
    "Motion creates emotion.",
    "Going outside is always the right call.",
    "Your future self is rooting for you.",
    "Even slow walkers arrive.",
    "Today's walk is tomorrow's streak.",
    "Steps add up. So does momentum.",
    "Be the reason someone else wants to walk.",
    "A walk a day keeps the funk away.",
    "The trail doesn't care about your mood.",
    "It's not about the distance. It's the direction.",
    "Walking is the best kind of thinking.",
    "Nature is free therapy.",
    "You are one walk away from a better mood.",
    "Keep going. You're already further than yesterday.",
    "The only bad walk is the one you didn't take.",
]
