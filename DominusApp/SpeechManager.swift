import AVFoundation
import AudioToolbox
import Accelerate
import Combine

/// High-gain TTS pipeline. Instead of playing through `AVSpeechSynthesizer.speak()`
/// (which is hard-capped at Apple's default output level), this routes the
/// synthesizer's raw PCM buffers through an `AVAudioEngine` chain:
///
///     synth.write → vDSP gain (~+8 dB) → player → peak limiter → output
///
/// vDSP multiplies the raw PCM samples by `speechGain` (AVAudioMixerNode's
/// outputVolume is clamped to 1.0, so the boost has to happen on the samples
/// themselves). The peak limiter catches any sample that would otherwise clip.
/// Net effect: TTS is noticeably louder than what AVSpeechSynthesizer can
/// produce on its own — same technique apps like Voice Dream Reader use.
///
/// "All speech finished" is determined by tracking buffer completion across
/// every utterance currently queued. When the last buffer of the last utterance
/// completes, `onAllSpeechFinished` fires.
@MainActor
final class SpeechManager: NSObject, ObservableObject {

    static let shared = SpeechManager()

    private let synth = AVSpeechSynthesizer()
    private var preferredVoice: AVSpeechSynthesisVoice?

    // MARK: - High-gain audio pipeline

    private let audioEngine = AVAudioEngine()
    private let playerNode  = AVAudioPlayerNode()
    private var limiter: AVAudioUnitEffect?
    /// Format used when wiring the engine. Determined from the very first
    /// synthesizer buffer and then reused for every subsequent connection.
    private var engineFormat: AVAudioFormat?
    private var engineConfigured = false

    /// Linear gain applied to TTS samples before the peak limiter. 2.5 ≈ +8 dB
    /// above what AVSpeechSynthesizer outputs on its own. The limiter prevents
    /// the extra gain from clipping on loud syllables.
    private let speechGain: Float = 2.5

    // MARK: - Bookkeeping

    /// Number of utterances queued whose audio has not yet fully played.
    private var outstandingUtterances: Int = 0
    /// Per-utterance buffer accounting. Keyed by utterance instance because the
    /// synth `write` callback fires once per buffer; we know an utterance is
    /// fully scheduled when it sends its zero-length terminating buffer.
    private var bufferQueue: [ObjectIdentifier: BufferQueueState] = [:]

    private struct BufferQueueState {
        var scheduled: Int = 0
        var completed: Int = 0
        var allBuffersScheduled: Bool = false
    }

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
        preferredVoice = pickMaleEnglishVoice()
    }

    // MARK: - Public API

    func prepareForVoiceMode() {
        if preferredVoice == nil {
            preferredVoice = pickMaleEnglishVoice()
        }
        prepareAudioSessionForSpeech()
    }

    /// Pre-load the AVSpeechSynthesizer voice file at app launch so the very first
    /// real call doesn't pay the cold voice-load delay. Renders a single inaudible
    /// space-character utterance through the engine to warm both the synthesizer
    /// and the gain-pipeline AU graph.
    func prewarmVoice() {
        if preferredVoice == nil {
            preferredVoice = pickMaleEnglishVoice()
        }
        prepareAudioSessionForSpeech()

        let warmupSynth = AVSpeechSynthesizer()
        let utt = AVSpeechUtterance(string: " ")
        utt.rate   = AVSpeechUtteranceDefaultSpeechRate
        utt.volume = 0
        utt.voice  = preferredVoice ?? AVSpeechSynthesisVoice(language: "en-US")
        utt.preUtteranceDelay  = 0
        utt.postUtteranceDelay = 0
        warmupSynth.write(utt) { _ in /* discard buffers */ }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            _ = warmupSynth   // keep alive until here
        }
    }

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
        scheduleUtteranceThroughEngine(utt)
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
        ThinkingFillerManager.shared.cancelScheduling()
        outstandingUtterances = 0
        bufferQueue.removeAll()
        isSpeaking            = false
        isStartingPlayback    = false
        nowPlayingMessageID   = nil
        synth.stopSpeaking(at: .immediate)
        if playerNode.isPlaying {
            playerNode.stop()
        }
    }

    // MARK: - Engine pipeline

    private func scheduleUtteranceThroughEngine(_ utt: AVSpeechUtterance) {
        let utteranceKey = ObjectIdentifier(utt)
        bufferQueue[utteranceKey] = BufferQueueState()

        // `synth.write` calls the callback once per output buffer. A buffer with
        // `frameLength == 0` signals end-of-utterance. The synthesiser invokes
        // the callback on a background thread, so we hop to the main actor for
        // state mutation and engine scheduling.
        synth.write(utt) { [weak self] buffer in
            guard let self else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            Task { @MainActor in
                self.handleSynthesizedBuffer(pcm, for: utteranceKey)
            }
        }
    }

    private func handleSynthesizedBuffer(_ buffer: AVAudioPCMBuffer,
                                         for utteranceKey: ObjectIdentifier) {
        // Zero-length buffer is the synthesizer's end-of-utterance marker.
        if buffer.frameLength == 0 {
            if var state = bufferQueue[utteranceKey] {
                state.allBuffersScheduled = true
                bufferQueue[utteranceKey] = state
                checkUtteranceCompletion(utteranceKey)
            }
            return
        }

        configureEngineIfNeeded(with: buffer.format)
        guard engineConfigured, audioEngine.isRunning else { return }

        // Apply the gain boost ONLY when output is the built-in speaker.
        // Headphones, AirPods, and Bluetooth keep their existing safety cap
        // (handled by `safeSpeechVolume()` on `utt.volume`) and receive no
        // extra boost — they are listened to up close and must not be louder
        // than Apple's default.
        let gain = currentSpeechGain()
        if gain != 1.0 {
            applyGain(gain, to: buffer)
        }

        if var state = bufferQueue[utteranceKey] {
            state.scheduled += 1
            bufferQueue[utteranceKey] = state
        }

        if isStartingPlayback {
            isStartingPlayback = false
        }

        playerNode.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleBufferCompletion(for: utteranceKey)
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    /// Per-route speech gain. Returns the full `speechGain` boost only when
    /// the user is listening on the device's built-in speaker. For headphones,
    /// AirPods, and Bluetooth output (any "private listening" route), returns
    /// 1.0 — no boost, so the headphone safety cap on `utt.volume` is the
    /// only thing controlling level. Output is then identical to stock Apple
    /// TTS, which is what the user expects when wearing headphones.
    private func currentSpeechGain() -> Float {
        let route = AVAudioSession.sharedInstance().currentRoute
        let isPrivateListening = route.outputs.contains { output in
            switch output.portType {
            case .headphones,
                 .bluetoothA2DP,
                 .bluetoothHFP,
                 .bluetoothLE,
                 .carAudio,
                 .airPlay:
                return true
            default:
                return false
            }
        }
        return isPrivateListening ? 1.0 : speechGain
    }

    /// Multiply every sample in every channel of `buffer` by `gain` using vDSP.
    /// In-place; safe because `synth.write` hands us a buffer we own.
    private func applyGain(_ gain: Float, to buffer: AVAudioPCMBuffer) {
        let frameCount = vDSP_Length(buffer.frameLength)
        guard frameCount > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)
        guard let channelData = buffer.floatChannelData else { return }
        var scale = gain
        for channel in 0 ..< channelCount {
            vDSP_vsmul(channelData[channel], 1, &scale, channelData[channel], 1, frameCount)
        }
    }

    private func handleBufferCompletion(for utteranceKey: ObjectIdentifier) {
        if var state = bufferQueue[utteranceKey] {
            state.completed += 1
            bufferQueue[utteranceKey] = state
        }
        checkUtteranceCompletion(utteranceKey)
    }

    private func checkUtteranceCompletion(_ utteranceKey: ObjectIdentifier) {
        guard let state = bufferQueue[utteranceKey] else { return }
        guard state.allBuffersScheduled, state.completed >= state.scheduled else { return }
        bufferQueue.removeValue(forKey: utteranceKey)
        handleUtteranceCompleted()
    }

    private func configureEngineIfNeeded(with format: AVAudioFormat) {
        if engineConfigured {
            if audioEngine.isRunning { return }
            do { try audioEngine.start() } catch {
                print("❌ TTS engine restart failed:", error.localizedDescription)
            }
            return
        }

        engineFormat = format

        let limiterDesc = AudioComponentDescription(
            componentType:         kAudioUnitType_Effect,
            componentSubType:      kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags:        0,
            componentFlagsMask:    0
        )
        let limiterUnit = AVAudioUnitEffect(audioComponentDescription: limiterDesc)
        self.limiter = limiterUnit

        audioEngine.attach(playerNode)
        audioEngine.attach(limiterUnit)

        // player (pre-gained samples) → limiter (catches peaks) → main mixer → output
        audioEngine.connect(playerNode,  to: limiterUnit,                format: format)
        audioEngine.connect(limiterUnit, to: audioEngine.mainMixerNode,  format: format)

        // Tune the peak limiter: very fast attack so the boost never clips
        // audibly, moderate release so the envelope doesn't pump on syllables.
        let au = limiterUnit.audioUnit
        AudioUnitSetParameter(au, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.001, 0)
        AudioUnitSetParameter(au, kLimiterParam_DecayTime,  kAudioUnitScope_Global, 0, 0.050, 0)
        AudioUnitSetParameter(au, kLimiterParam_PreGain,    kAudioUnitScope_Global, 0, 0,     0)

        audioEngine.prepare()
        do {
            try audioEngine.start()
            engineConfigured = true
        } catch {
            print("❌ TTS engine start failed:", error.localizedDescription)
        }
    }

    private func prepareAudioSessionForSpeech() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Use `.playback` (not `.playAndRecord`) while the AI is speaking.
            // `.playAndRecord` is a conversational category and iOS attenuates
            // its output ~6-10 dB below `.playback` even with `.spokenAudio`
            // mode. `.playback` uses the loud audiobook/media path — same as
            // Audible, Spotify, and ChatGPT voice. When the user starts
            // talking again, `WhisperManager.setupAudioSession()` flips the
            // category back to `.playAndRecord` for recording. The mic is off
            // during AI speech, so voice barge-in is disabled — the user
            // interrupts by tapping the orb.
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers]
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

        let routeCap: Float = isPrivateListening ? 0.48 : 1.0
        let userVolume = Float(AudioSettingsStore.shared.aiVoiceResponseVolume)
        return min(1.0, max(0.0, routeCap * userVolume))
    }

    // MARK: - Completion tracking
    //
    // The pipeline now uses `synth.write` instead of `synth.speak`, so the
    // delegate `didFinish`/`didCancel` callbacks do not fire. Completion is
    // driven from `scheduleBuffer`'s completion handler — when every buffer
    // of every queued utterance has finished playing, we fire
    // `onAllSpeechFinished` just like before.

    private func handleUtteranceCompleted() {
        outstandingUtterances = max(0, outstandingUtterances - 1)
        if outstandingUtterances == 0 {
            isSpeaking          = false
            isStartingPlayback  = false
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
