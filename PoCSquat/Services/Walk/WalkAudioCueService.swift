import AVFoundation
import Observation

// MARK: - WalkAudioCueService
//
// Speaks each split during a walk, run or ride so users can leave their
// phone in their pocket.
//
// Units: a split is every whole mile in the US and every whole kilometre
// elsewhere, the rule every other screen uses, and pace is spoken in the
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

    /// "1 hour 2 minutes 5 seconds", "9 minutes", "40 seconds": whole seconds,
    /// with the parts that are zero left out.
    nonisolated static func spokenDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) \(h == 1 ? "hour" : "hours")") }
        if m > 0 { parts.append("\(m) \(m == 1 ? "minute" : "minutes")") }
        if s > 0 || parts.isEmpty { parts.append("\(s) \(s == 1 ? "second" : "seconds")") }
        return parts.joined(separator: " ")
    }

    /// What is said when a split completes (`feat/run-pace-splits`). A walk
    /// or run hears the unit, the moving time, that split's pace and the
    /// average pace, each named for what it is: "Mile 2. Time 18 minutes 40
    /// seconds. Last mile 9 minutes 12 seconds. Average pace 9 minutes 20
    /// seconds per mile." Until 2026-10-14 it said "Current pace" for the
    /// average. A ride hears its average speed instead of a pace.
    nonisolated static func splitCueText(split number: Int, unitMeters: Double,
                                         elapsed: TimeInterval, splitSeconds: TimeInterval,
                                         mode: ActivityMode) -> String {
        let usesMiles = unitMeters != 1000
        let unit = usesMiles ? "mile" : "kilometer"
        let units = Double(number)
        var text = "\(unit.capitalized) \(number). Time \(spokenDuration(elapsed))."
        if mode == .cycling {
            let perHour = units / (elapsed / 3600)
            text += String(format: " Average speed %.1f %@ per hour.", perHour, usesMiles ? "miles" : "kilometers")
        } else {
            text += " Last \(unit) \(spokenDuration(splitSeconds))."
            text += " Average pace \(spokenDuration(elapsed / units)) per \(unit)."
        }
        return text
    }

    // MARK: - Called by NavigationSessionManager when a split completes

    /// Announces a completed split. The session's `SplitTracker` reports each
    /// split once, a restored session included, so this keeps no count.
    func announceSplit(number: Int, unitMeters: Double, elapsed: TimeInterval,
                       splitSeconds: TimeInterval, mode: ActivityMode) {
        guard isEnabled, mode != .stationary else { return }
        speak(Self.splitCueText(split: number, unitMeters: unitMeters, elapsed: elapsed,
                                splitSeconds: splitSeconds, mode: mode))
    }

    /// One-shot announcements for discrete events (walk complete, PR set, checkpoint).
    func announce(_ message: String) {
        guard isEnabled else { return }
        speak(message)
    }

    func reset() {
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
