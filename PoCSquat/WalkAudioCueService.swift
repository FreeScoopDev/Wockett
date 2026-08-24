import AVFoundation
import MapKit
import Observation

// MARK: - WalkAudioCueService
//
// Speaks distance and pace milestones during a walk so users can leave their
// phone in their pocket. Uses AVSpeechSynthesizer with a ducked audio session
// so music continues at lower volume while cues play.

@MainActor
@Observable
final class WalkAudioCueService: NSObject {
    static let shared = WalkAudioCueService()

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: udKey) }
    }

    private let synth   = AVSpeechSynthesizer()
    private let udKey   = "audioCues_enabled"
    private let distanceFormatter = MKDistanceFormatter.abbreviated

    // Track the last km milestone announced to avoid repeating
    private var lastAnnouncedKm: Int = 0
    // Track last pace announcement time to avoid spamming
    private var lastPaceAnnouncement: Date = .distantPast

    private override init() {
        isEnabled = UserDefaults.standard.object(forKey: "audioCues_enabled") as? Bool ?? true
        super.init()
        configureAudioSession()
    }

    // MARK: - Called by NavigationSessionManager on each location update

    /// Announces km milestones and optionally pace. Call whenever distance or pace changes.
    func update(distanceCoveredMeters: Double, paceSecsPerKm: Double?, activityMode: ActivityMode) {
        guard isEnabled else { return }

        let kmCovered = Int(distanceCoveredMeters / 1000)
        if kmCovered > lastAnnouncedKm {
            lastAnnouncedKm = kmCovered
            announceKilometer(km: kmCovered, paceSecsPerKm: paceSecsPerKm, activityMode: activityMode)
        }
    }

    /// One-shot announcements for discrete events (walk complete, PR set, checkpoint).
    func announce(_ message: String) {
        guard isEnabled else { return }
        speak(message)
    }

    func reset() {
        lastAnnouncedKm = 0
        lastPaceAnnouncement = .distantPast
        synth.stopSpeaking(at: .immediate)
    }

    // MARK: - Private

    private func announceKilometer(km: Int, paceSecsPerKm: Double?, activityMode: ActivityMode) {
        let unit = Locale.current.measurementSystem == .metric ? "kilometer" : "mile"
        let unitPlural = km == 1 ? unit : "\(unit)s"
        var message = "\(km) \(unitPlural) completed."

        if let pace = paceSecsPerKm, activityMode != .stationary {
            let mins = Int(pace) / 60
            let secs = Int(pace) % 60
            let paceStr = secs == 0 ? "\(mins) minutes per kilometer" : "\(mins) minutes \(secs) seconds per kilometer"
            message += " Current pace: \(paceStr)."
        }

        speak(message)
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        utterance.rate  = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.0
        utterance.volume = 0.9
        synth.speak(utterance)
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}
