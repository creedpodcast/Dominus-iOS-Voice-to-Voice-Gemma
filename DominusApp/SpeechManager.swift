import AVFoundation

@MainActor
final class SpeechManager: NSObject, AVSpeechSynthesizerDelegate {

    static let shared = SpeechManager()

    private let synth = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var isSpeakingChunk = false
    private var preferredVoice: AVSpeechSynthesisVoice?

    // ✅ NEW: Called when ALL queued speech is finished
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

        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
    }

    private func startIfNeeded() {
        guard !isSpeakingChunk else { return }
        guard !queue.isEmpty else { return }
        isSpeakingChunk = true
        speakNext()
    }

    private func speakNext() {
        guard !queue.isEmpty else {
            isSpeakingChunk = false
            onAllSpeechFinished?()
            return
        }

        // Only switch to playback right before speaking (keeps mic stable)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            print("TTS audio session error:", error)
        }

        let chunk = queue.removeFirst()
        let utt = AVSpeechUtterance(string: chunk)
        utt.rate = AVSpeechUtteranceDefaultSpeechRate
        utt.voice = preferredVoice ?? AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(utt)
    }

    private func clean(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "```", with: "")

        // Remove emojis so it doesn’t speak them
        s = s.unicodeScalars.filter { scalar in
            if scalar.properties.isEmojiPresentation { return false }
            if scalar.properties.isEmoji { return false }
            if scalar.value == 0xFE0F { return false }
            if scalar.value == 0x200D { return false }
            return true
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

        print("🎙 Voice selected:", best.name, "|", best.language, "| quality:", best.quality.rawValue, "| id:", best.identifier)
        return best
    }

    // MARK: - Delegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        speakNext()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if !queue.isEmpty {
            speakNext()
        } else {
            isSpeakingChunk = false
            onAllSpeechFinished?()
        }
    }
}
