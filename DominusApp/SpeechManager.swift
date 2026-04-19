import AVFoundation
import Combine

@MainActor
final class SpeechManager: NSObject, AVSpeechSynthesizerDelegate {

    static let shared = SpeechManager()

    private let synth = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var isSpeakingChunk = false
    private var preferredVoice: AVSpeechSynthesisVoice?

    /// True while the synthesizer is actively speaking — used by VAD logic
    @Published var isSpeaking: Bool = false

    var onAllSpeechFinished: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
        preferredVoice = pickBestEnglishVoice()
    }

    func enqueue(_ text: String) {
        let cleaned = clean(text)
        guard !cleaned.isEmpty else { return }
        queue.append(cleaned)
        startIfNeeded()
    }

    func stopAndClear() {
        queue.removeAll()
        isSpeakingChunk = false
        isSpeaking      = false
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
    }

    private func startIfNeeded() {
        guard !isSpeakingChunk, !queue.isEmpty else { return }
        isSpeakingChunk = true
        speakNext()
    }

    private func speakNext() {
        guard !queue.isEmpty else {
            isSpeakingChunk = false
            isSpeaking      = false
            onAllSpeechFinished?()
            return
        }

        // ── No audio session setup here ──────────────────────────────────
        // The unified voiceChat session set up by SpeechRecognitionManager
        // is already active and handles both playback and record together.
        // Switching sessions here is what caused the echo and choppy audio.

        let chunk = queue.removeFirst()
        let utt   = AVSpeechUtterance(string: chunk)
        utt.rate  = AVSpeechUtteranceDefaultSpeechRate
        utt.voice = preferredVoice ?? AVSpeechSynthesisVoice(language: "en-US")
        isSpeaking = true
        synth.speak(utt)
    }

    private func clean(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "```", with: "")
        s = s.unicodeScalars.filter { scalar in
            !scalar.properties.isEmojiPresentation &&
            !scalar.properties.isEmoji &&
            scalar.value != 0xFE0F &&
            scalar.value != 0x200D
        }
        .map(String.init)
        .joined()
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pickBestEnglishVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        guard let best = english.max(by: { $0.quality.rawValue < $1.quality.rawValue }) else {
            print("🎙 No English voices found.")
            return nil
        }
        print("🎙 Voice selected:", best.name, "|", best.language, "| quality:", best.quality.rawValue)
        return best
    }

    // MARK: - Delegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        speakNext()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        if !queue.isEmpty {
            speakNext()
        } else {
            isSpeakingChunk = false
            onAllSpeechFinished?()
        }
    }
}
