import SwiftUI

// MARK: - Banner Store

@Observable
final class BannerStore {
    static let shared = BannerStore()

    var userAffirmations: [String] = []
    private let udKey = "bannerAffirmations_v1"

    private init() { load() }

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
}

// MARK: - Rotating Banner Title

struct BannerTitleView: View {
    private var store = BannerStore.shared
    @State private var phase = 0            // 0 = "Wockett", 1…n = quote index
    @State private var opacity: Double = 1
    @State private var shuffled: [String] = []

    private var total: Int { 1 + shuffled.count }

    var body: some View {
        Group {
            if phase == 0 || shuffled.isEmpty {
                Text("Wockett")
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .foregroundColor(.earthCream)
            } else {
                Text(shuffled[(phase - 1) % shuffled.count])
                    .font(.system(size: 11, weight: .medium))
                    .italic()
                    .foregroundColor(.earthMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 220)
                    .minimumScaleFactor(0.8)
            }
        }
        .opacity(opacity)
        .onAppear { shuffled = store.allQuotes.shuffled() }
        .task(id: 0) { await cycle() }
    }

    private func cycle() async {
        while true {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            withAnimation(.easeOut(duration: 0.3)) { opacity = 0 }
            try? await Task.sleep(nanoseconds: 320_000_000)
            phase = (phase + 1) % max(total, 1)
            withAnimation(.easeIn(duration: 0.3)) { opacity = 1 }
        }
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
