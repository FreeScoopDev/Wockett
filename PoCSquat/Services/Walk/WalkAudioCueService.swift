import AVFoundation
import Observation

// MARK: - WalkAudioCueService
//
// Speaks distance and pace milestones during a walk so users can leave their
// phone in their pocket.
//
// Units: a milestone is every whole mile in the US and every whole kilometre
// elsewhere, the rule every other screen uses, and the pace is spoken in the
// same unit. Until 2026-09-28 the counter ticked every kilometre and then
// named the unit by locale, so a US phone heard "1 mile completed" after one
// kilometre, and pace was always "per kilometer".
//
// Audio: other audio is ducked only while a cue is speaking. The session is
// activated before an utterance and released when the last queued utterance
// has finished, with notifyOthersOnDeactivation so music comes back up.
// Until 2026-09-28 the session was activated once, at first use, and never
// released, so music stayed quiet for the whole walk.

@MainActor
@Observable
final class WalkAudioCueService: NSObject {
    static let shared = WalkAudioCueService()

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: udKey) }
    }

    private let synth   = AVSpeechSynthesizer()
    private let udKey   = "audioCues_enabled"

    // The last whole unit (mile or kilometre) announced, so each is said once.
    private var lastAnnouncedUnits: Int = 0

    // Utterances handed to the synthesizer that it has not finished or
    // cancelled yet. The audio session is released when this reaches zero;
    // it is our own count rather than `synth.isSpeaking` because that flag
    // is not documented to be clear by the time the delegate is called.
    private var pendingUtterances = 0

    private override init() {
        isEnabled = UserDefaults.standard.object(forKey: "audioCues_enabled") as? Bool ?? true
        super.init()
        synth.delegate = self
        // Category only. The session is activated per utterance, in speak().
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        )
    }

    // MARK: - Units

    /// Miles in the US, kilometres everywhere else: the rule the rest of the
    /// app follows (`Locale.current.measurementSystem == .us` means miles).
    nonisolated static var usesMiles: Bool { Locale.current.measurementSystem == .us }

    nonisolated static let metersPerMile = 1609.344

    /// Whole units covered so far: the milestone counter.
    nonisolated static func unitsCovered(meters: Double, usesMiles: Bool) -> Int {
        Int(meters / (usesMiles ? metersPerMile : 1000))
    }

    /// "2 miles completed." / "1 kilometer completed."
    nonisolated static func milestoneText(units: Int, usesMiles: Bool) -> String {
        let unit = usesMiles ? "mile" : "kilometer"
        return "\(units) \(units == 1 ? unit : unit + "s") completed."
    }

    /// "Current pace: 9 minutes 39 seconds per mile." The pace arrives per
    /// kilometre whatever the locale, and is converted for the spoken unit.
    nonisolated static func paceText(secsPerKm: Double, usesMiles: Bool) -> String {
        let secsPerUnit = usesMiles ? secsPerKm * metersPerMile / 1000 : secsPerKm
        let mins = Int(secsPerUnit) / 60
        let secs = Int(secsPerUnit) % 60
        let unit = usesMiles ? "mile" : "kilometer"
        return secs == 0
            ? "Current pace: \(mins) minutes per \(unit)."
            : "Current pace: \(mins) minutes \(secs) seconds per \(unit)."
    }

    // MARK: - Called by NavigationSessionManager on each location update

    /// Announces each whole mile or kilometre, with the pace. Call whenever
    /// distance or pace changes.
    func update(distanceCoveredMeters: Double, paceSecsPerKm: Double?, activityMode: ActivityMode) {
        guard isEnabled else { return }
        let usesMiles = Self.usesMiles
        let covered = Self.unitsCovered(meters: distanceCoveredMeters, usesMiles: usesMiles)
        guard covered > lastAnnouncedUnits else { return }
        lastAnnouncedUnits = covered

        var message = Self.milestoneText(units: covered, usesMiles: usesMiles)
        if let pace = paceSecsPerKm, activityMode != .stationary {
            message += " " + Self.paceText(secsPerKm: pace, usesMiles: usesMiles)
        }
        speak(message)
    }

    /// One-shot announcements for discrete events (walk complete, PR set, checkpoint).
    func announce(_ message: String) {
        guard isEnabled else { return }
        speak(message)
    }

    func reset() {
        lastAnnouncedUnits = 0
        pendingUtterances = 0
        synth.stopSpeaking(at: .immediate)
        releaseAudioSession()
    }

    // MARK: - Private

    private func speak(_ text: String) {
        // Duck other audio for this cue only; utteranceEnded() releases the
        // session once nothing is left to say.
        pendingUtterances += 1
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        utterance.rate  = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.0
        utterance.volume = 0.9
        synth.speak(utterance)
    }

    private func utteranceEnded() {
        pendingUtterances = max(0, pendingUtterances - 1)
        if pendingUtterances == 0 { releaseAudioSession() }
    }

    /// Lets other audio come back up. Deactivation is refused while audio is
    /// still running, which is harmless: the next finished cue tries again.
    private func releaseAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// The synthesizer does not promise which thread it calls back on, so the
// delegate methods are nonisolated and hop to the main actor.
extension WalkAudioCueService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }
}
