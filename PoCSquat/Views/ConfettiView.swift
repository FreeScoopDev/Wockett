import SwiftUI

// Randomly picks one of two styles each time it appears.
struct ConfettiOverlay: View {
    private struct Particle {
        let x: CGFloat          // 0–1 relative to width
        let startY: CGFloat     // offset above the top edge
        let drift: CGFloat      // horizontal drift in points
        let rotStart: Double
        let rotEnd: Double
        let color: Color
        let width: CGFloat
        let height: CGFloat
        let isRound: Bool
        let delay: Double
        let duration: Double
    }

    @State private var particles: [Particle] = []
    @State private var animating = false

    private static func makeParticles() -> [Particle] {
        let golden = Bool.random()
        let palette: [Color] = golden
            ? [.yellow, Color(red: 1, green: 0.84, blue: 0), .white, Color(red: 0.8, green: 0.8, blue: 0.8)]
            : [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]
        return (0..<100).map { _ in
            Particle(
                x:         .random(in: 0.02...0.98),
                startY:    .random(in: 20...100),
                drift:     .random(in: -70...70),
                rotStart:  .random(in: 0...360),
                rotEnd:    .random(in: -720...720),
                color:     palette.randomElement()!,
                width:     .random(in: 7...13),
                height:    golden ? .random(in: 7...13) : .random(in: 4...7),
                isRound:   golden ? Bool.random() : false,
                delay:     .random(in: 0...1.4),
                duration:  .random(in: 2.0...3.5)
            )
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(particles.indices, id: \.self) { i in
                    let p = particles[i]
                    Group {
                        if p.isRound {
                            Circle().fill(p.color).frame(width: p.width, height: p.width)
                        } else {
                            RoundedRectangle(cornerRadius: 2).fill(p.color).frame(width: p.width, height: p.height)
                        }
                    }
                    .rotationEffect(.degrees(animating ? p.rotEnd : p.rotStart))
                    .position(
                        x: geo.size.width * p.x + (animating ? p.drift : 0),
                        y: animating ? geo.size.height + 80 : -p.startY
                    )
                    .animation(.easeIn(duration: p.duration).delay(p.delay), value: animating)
                }
            }
        }
        .onAppear {
            particles = Self.makeParticles()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { animating = true }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
