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
/// Volume is controlled by the audio session mode, the device volume rocker, and
/// a route-aware app cap so headphones/Bluetooth do not play at full blast.
@MainActor
final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    static let shared = SpeechManager()

    private let synth = AVSpeechSynthesizer()
    private var preferredVoice: AVSpeechSynthesisVoice?

    /// Number of utterances queued with `speak()` that haven't finished yet.
    private var outstandingUtterances: Int = 0

    /// True while any utterance is queued or actively playing
    @Published var isSpeaking: Bool = false

    /// ID of the chat message currently being read aloud via `speak(_:for:)`.
    /// `nil` when nothing is playing or when streaming live generation TTS.
    @Published var nowPlayingMessageID: UUID?

    /// True from the moment `speak(_:for:)` is called until the synthesizer
    /// fires its `didStart` callback — the brief window where audio is initialising.
    @Published var isStartingPlayback: Bool = false

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
        guard hasSpeakableContent(cleaned) else { return }

        prepareAudioSessionForSpeech()

        let utt    = AVSpeechUtterance(string: cleaned)
        utt.rate   = AVSpeechUtteranceDefaultSpeechRate
        utt.volume = safeSpeechVolume()
        utt.voice  = preferredVoice ?? AVSpeechSynthesisVoice(language: "en-US")
        utt.preUtteranceDelay  = 0
        utt.postUtteranceDelay = 0

        outstandingUtterances += 1
        isSpeaking = true
        synth.speak(utt)
    }

    /// Speak `text` and tag the playback with `id` so per-message UI can show a
    /// stop icon while this exact message is reading. Cancels anything currently
    /// playing first.
    func speak(_ text: String, for id: UUID) {
        stopAndClear()
        nowPlayingMessageID  = id
        isStartingPlayback   = true
        enqueue(text)
    }

    func stopAndClear() {
        outstandingUtterances = 0
        isSpeaking            = false
        isStartingPlayback    = false
        nowPlayingMessageID   = nil
        synth.stopSpeaking(at: .immediate)
    }

    private func prepareAudioSessionForSpeech() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .videoChat,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("❌ TTS audio session setup failed:", error.localizedDescription)
        }
    }

    private func safeSpeechVolume() -> Float {
        let route = AVAudioSession.sharedInstance().currentRoute
        let isPrivateListening = route.outputs.contains { output in
            switch output.portType {
            case .headphones,
                 .bluetoothA2DP,
                 .bluetoothHFP,
                 .bluetoothLE:
                return true
            default:
                return false
            }
        }

        return isPrivateListening ? 0.34 : 0.85
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        // First word is about to be spoken — audio pipeline is live, clear the
        // "starting" spinner so the UI settles into the active-playback state.
        Task { @MainActor in self.isStartingPlayback = false }
    }

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
            isSpeaking          = false
            nowPlayingMessageID = nil
            onAllSpeechFinished?()
        }
    }

    // MARK: - Text cleaning (industry-standard TTS preprocessing)
    //
    // Goal: produce plain spoken-word text that AVSpeechSynthesizer will read
    // naturally without vocalising formatting symbols or punctuation names.
    //
    // Pipeline (in order):
    //   1. Strip fenced + inline code blocks
    //   2. Unwrap markdown emphasis/headers/lists → plain words
    //   3. Expand common symbols to spoken equivalents (&→and, @→at, %→percent)
    //   4. Convert verbal punctuation artifacts like "period" into real pauses
    //   5. Normalise ellipsis so it becomes a natural pause, not "dot dot dot"
    //   6. Strip any remaining non-speech Unicode (emoji, ZWJ sequences, etc.)
    //   7. Collapse whitespace

    private func clean(_ text: String) -> String {
        var s = text

        // 1. Code blocks — remove entirely (code is unreadable aloud)
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "`[^`\n]*`",        with: " ", options: .regularExpression)

        // 2. Markdown formatting — strip markers, keep inner text
        //    Bold/italic: ***x*** **x** *x*
        s = s.replacingOccurrences(of: "\\*{1,3}([^*\n]+)\\*{1,3}", with: "$1", options: .regularExpression)
        //    Underline/italic: __x__ _x_
        s = s.replacingOccurrences(of: "_{1,2}([^_\n]+)_{1,2}",     with: "$1", options: .regularExpression)
        //    Strikethrough: ~~x~~
        s = s.replacingOccurrences(of: "~~([^~\n]+)~~",              with: "$1", options: .regularExpression)
        //    ATX headers: # Heading → Heading
        s = s.replacingOccurrences(of: "(?m)^#{1,6}\\s*",            with: "",   options: .regularExpression)
        //    Blockquotes: > text → text
        s = s.replacingOccurrences(of: "(?m)^>\\s*",                 with: "",   options: .regularExpression)
        //    Unordered list bullets: - / * / + at line start
        s = s.replacingOccurrences(of: "(?m)^[-*+]\\s+",             with: "",   options: .regularExpression)
        //    Ordered list numbers: 1. 2. etc.
        s = s.replacingOccurrences(of: "(?m)^\\d+\\.\\s+",           with: "",   options: .regularExpression)
        //    Bare URLs — replace with nothing (not speakable)
        s = s.replacingOccurrences(of: "https?://\\S+",               with: "",   options: .regularExpression)

        // 3. Symbol expansion
        s = s.replacingOccurrences(of: " & ",  with: " and ")
        s = s.replacingOccurrences(of: " @ ",  with: " at ")
        s = s.replacingOccurrences(of: " % ",  with: " percent ")
        s = s.replacingOccurrences(of: " / ",  with: " or ")   // "yes / no" → "yes or no"
        s = s.replacingOccurrences(of: " + ",  with: " plus ")
        s = s.replacingOccurrences(of: " = ",  with: " equals ")
        s = s.replacingOccurrences(of: "#",    with: "")       // stray hash
        s = s.replacingOccurrences(of: "|",    with: " ")      // table pipes

        // 4. Convert verbal punctuation artifacts that occasionally appear in
        //    generated text or dictated transcripts and would be read aloud.
        s = stripVerbalPunctuation(from: s)

        // 5. Ellipsis normalisation — "..." → natural pause (…), not "dot dot dot"
        s = s.replacingOccurrences(of: "\\.\\.\\.", with: "\u{2026}", options: .regularExpression)

        // 6. Strip emoji and non-speech Unicode (ZWJ, variation selectors, etc.)
        s = s.unicodeScalars.filter { scalar in
            !scalar.properties.isEmojiPresentation &&
            !scalar.properties.isEmoji &&
            scalar.value != 0xFE0F &&   // variation selector-16
            scalar.value != 0x200D      // ZWJ
        }
        .map(String.init)
        .joined()

        // 7. Collapse runs of whitespace / newlines into a single space
        s = s.replacingOccurrences(of: "[ \\t]+",  with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{2,}", with: ". ", options: .regularExpression)  // paragraph break → spoken pause
        s = s.replacingOccurrences(of: "\\n",     with: " ",  options: .regularExpression)

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripVerbalPunctuation(from text: String) -> String {
        var s = text

        let replacements: [(pattern: String, replacement: String)] = [
            ("(?i)\\b(?:period|full stop)\\b[\\.,!?:;]*", ". "),
            ("(?i)\\bcomma\\b[\\.,!?:;]*", ", "),
            ("(?i)\\b(?:question mark)\\b[\\.,!?:;]*", "? "),
            ("(?i)\\b(?:exclamation point|exclamation mark)\\b[\\.,!?:;]*", "! ")
        ]

        for item in replacements {
            s = s.replacingOccurrences(
                of: item.pattern,
                with: item.replacement,
                options: .regularExpression
            )
        }

        // Skip fragments that are only punctuation instead of letting AVSpeech
        // read them as punctuation names.
        s = s.replacingOccurrences(of: "\\s+([\\.,!?:;])", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "([\\.,!?:;]){2,}", with: "$1", options: .regularExpression)
        return s
    }

    private func hasSpeakableContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
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
