import AVFoundation
import Combine

/// Industry-standard TTS pipeline using `AVSpeechSynthesizer.speak()` + delegate.
/// Apple handles sentence sequencing internally — no gaps, no duplicates, rock-solid timing.
///
/// "All speech finished" is determined by tracking outstanding utterances:
///  - increment when `speak()` is called
///  - decrement in `didFinish` delegate callback
///  - fire `onAllSpeechFinished` only when the count returns to zero
///
/// Volume is controlled by the audio session mode (.videoChat removes AGC cap)
/// and the device volume rocker. `AVSpeechUtterance.volume` is held at 1.0 (max).
@MainActor
final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    static let shared = SpeechManager()

    private let synth = AVSpeechSynthesizer()
    private var preferredVoice: AVSpeechSynthesisVoice?

    /// Number of utterances queued with `speak()` that haven't finished yet.
    private var outstandingUtterances: Int = 0

    /// True while any utterance is queued or actively playing
    @Published var isSpeaking: Bool = false

    /// Fires once when ALL queued utterances have finished playing.
    var onAllSpeechFinished: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
        preferredVoice = pickMaleEnglishVoice()
    }

    // MARK: - Public API

    func enqueue(_ text: String) {
        let cleaned = clean(text)
        guard !cleaned.isEmpty else { return }

        let utt    = AVSpeechUtterance(string: cleaned)
        utt.rate   = AVSpeechUtteranceDefaultSpeechRate
        utt.volume = 1.0
        utt.voice  = preferredVoice ?? AVSpeechSynthesisVoice(language: "en-US")
        utt.preUtteranceDelay  = 0
        utt.postUtteranceDelay = 0

        outstandingUtterances += 1
        isSpeaking = true
        synth.speak(utt)
    }

    func stopAndClear() {
        outstandingUtterances = 0
        isSpeaking            = false
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.handleUtteranceCompleted() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.handleUtteranceCompleted() }
    }

    private func handleUtteranceCompleted() {
        outstandingUtterances = max(0, outstandingUtterances - 1)
        if outstandingUtterances == 0 {
            isSpeaking = false
            onAllSpeechFinished?()
        }
    }

    // MARK: - Text cleaning

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

    // MARK: - Voice selection

    private func pickMaleEnglishVoice() -> AVSpeechSynthesisVoice? {
        let allVoices = AVSpeechSynthesisVoice.speechVoices()

        let english = allVoices.filter { $0.language.hasPrefix("en") }
        print("🎙 Available English voices:")
        english.forEach { print("   \($0.name) | \($0.language) | quality: \($0.quality.rawValue)") }

        let preferredNames = ["Evan", "Nathan", "Tom", "Reed", "Aaron", "Gordon", "Fred"]
        for name in preferredNames {
            if let v = allVoices.first(where: {
                $0.language == "en-US" && $0.name.hasPrefix(name)
            }) {
                print("🎙 Voice selected:", v.name, "|", v.language, "| quality:", v.quality.rawValue)
                return v
            }
        }

        guard let best = english.max(by: { $0.quality.rawValue < $1.quality.rawValue }) else {
            print("🎙 No English voices found, using default.")
            return nil
        }
        print("🎙 Voice selected:", best.name, "|", best.language, "| quality:", best.quality.rawValue)
        return best
    }
}
