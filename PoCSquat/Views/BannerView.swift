import SwiftUI

// MARK: - Banner Store

// The quotes behind the line at the foot of Home's hero card. Until the
// 2026-09-30 redesign they rotated every 4.5 s in the navigation bar; now one
// is picked when Home is first shown, so it reads as a sentence, not a ticker.
// The user's own affirmations (Settings → Motivational Quotes) join the draw.
@Observable
final class BannerStore {
    static let shared = BannerStore()

    var userAffirmations: [String] = []

    private let udKey = "bannerAffirmations_v1"

    init() { load() }

    var allQuotes: [String] { curatedQuotes + userAffirmations }

    /// One quote for Home's hero card.
    func randomQuote() -> String {
        allQuotes.randomElement() ?? "Your best walk is still ahead."
    }

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
