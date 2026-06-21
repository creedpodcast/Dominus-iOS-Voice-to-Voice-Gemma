import Foundation
import AVFoundation
import WhisperKit
import Accelerate
import Combine

/// Handles PTT voice recording and on-device transcription via WhisperKit.
///
/// Flow:
///   1. Call `loadModel()` once on app boot — downloads + caches the Whisper model.
///   2. Call `startRecording()` when the user opens the PTT session.
///   3. Call `stopAndTranscribe()` when the user taps send — returns the full transcript.
///
/// This is now the sole STT path. The legacy `SpeechRecognitionManager`
/// (SFSpeechRecognizer) lives under `/Archive` and is no longer in the build;
/// this manager owns audio session setup, recording, VAD amplitude monitoring,
/// and transcription end-to-end.
@MainActor
final class WhisperManager: ObservableObject {

    static let shared = WhisperManager()

    // MARK: - Published state

    @Published var isRecording:        Bool   = false
    @Published var isStartingRecording: Bool   = false  // true from tap until engine is live
    @Published var isTranscribing:      Bool   = false
    @Published var audioLevel:      Float  = 0.0
    /// User-controlled mic kill-switch. When true, incoming audio is discarded
    /// (engine keeps running for instant resume). The user toggles this from
    /// the orb overlay so they don't accidentally transcribe stray words.
    @Published var isMicMuted:      Bool   = false
    @Published var modelReady:      Bool   = false
    @Published var isLoadingModel:  Bool   = false
    @Published var loadProgress:    Double = 0.0
    @Published var modelStatus:     String = "Whisper not loaded"
    @Published var liveTranscript:  String = ""
    @Published var lastRecordingDuration: TimeInterval = 0
    @Published private(set) var lastSpeechActivityAt: Date?
    /// Compatibility signal for older call sites. This now tracks speech-like
    /// activity, not every raw mic sound.
    @Published var lastAudioActivityAt: Date?
    private(set) var lastSoundActivityAt: Date?
    private(set) var adaptiveNoiseFloor: Float = 0.012

    // MARK: - Private

    private var whisperKit:      WhisperKit?
    private let audioEngine    = AVAudioEngine()
    private var recordedSamples: [Float]  = []
    private var nativeSampleRate: Double  = 44_100
    private var recordingStartedAt: Date?
    private var bestLiveTranscript: String = ""
    private var bestRawLiveTranscript: String = ""
    private let minimumSoundActivityLevel: Float = 0.02
    private let soundActivityNoiseMargin: Float = 0.08
    private let noiseFloorRiseSmoothing: Float = 0.015
    private let noiseFloorFallSmoothing: Float = 0.12
    private let noiseFloorMaxLevel: Float = 0.30

    /// Speech probability threshold for the Silero VAD activity signal.
    /// 0.5 = balanced default. Bump to 0.6–0.7 for noisier environments
    /// (suppresses borderline classifications).
    private let vadSpeechThreshold: Float = 0.5

    /// Accumulates raw mic samples (at hardware native rate) waiting to
    /// be resampled to 16 kHz and fed to VAD in model-sized chunks.
    private var vadInputBuffer: [Float] = []

    /// Periodically prints VAD score summaries (peak/avg/threshold-crossing
    /// rate) so we can tune. Logs once per second to keep the console
    /// readable. Set `verbose = true` to dump every score.
    private var vadDiagnostic = VADDiagnostic()

    /// Decoder options applied to every WhisperKit transcribe call.
    ///
    /// Two industry-standard noise-rejection layers stacked:
    ///   - `chunkingStrategy: .vad` — WhisperKit's built-in Voice Activity
    ///     Detection pre-filter. Discards audio chunks that the VAD model
    ///     thinks are not speech BEFORE Whisper sees them, so noise can't
    ///     turn into phantom words.
    ///   - `noSpeechThreshold: 0.7` (up from default 0.6) — Whisper's own
    ///     confidence threshold for declaring a segment as silence.
    ///     Slightly more aggressive than the default; rare cases of
    ///     dropping quiet legitimate speech are caught by the VAD layer.
    private static let tunedDecodingOptions: DecodingOptions = {
        DecodingOptions(
            noSpeechThreshold: 0.7,
            chunkingStrategy: .vad
        )
    }()

    private var liveTimer:               Timer?
    private var isRunningLivePass:       Bool  = false

    private init() {}

    // MARK: - Model loading

    /// Downloads and caches the Whisper base-English model (~145 MB, once only).
    /// Call from ContentView.task — safe to call multiple times.
    func loadModel() async {
        guard !modelReady, !isLoadingModel else { return }
        isLoadingModel = true
        loadProgress   = 0.0
        modelStatus    = "Checking Whisper model…"

        // Staged progress animation that runs while the real async load is in flight.
        let progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, let self else { break }
                if self.loadProgress < 0.30 {
                    self.loadProgress = min(self.loadProgress + 0.025, 0.30)
                } else if self.loadProgress < 0.80 {
                    self.loadProgress = min(self.loadProgress + 0.012, 0.80)
                } else if self.loadProgress < 0.95 {
                    self.loadProgress = min(self.loadProgress + 0.004, 0.95)
                }
            }
        }

        do {
            modelStatus = "Loading Whisper model…"
            whisperKit  = try await WhisperKit(model: "openai_whisper-base.en")
            progressTask.cancel()
            loadProgress   = 1.0
            modelReady     = true
            isLoadingModel = false
            modelStatus    = "Whisper ready"
            print("✅ WhisperKit loaded")
        } catch {
            progressTask.cancel()
            loadProgress   = 0.0
            isLoadingModel = false
            modelStatus    = "Whisper load failed: \(error.localizedDescription)"
            print("❌ WhisperKit load error:", error)
        }
    }

    // MARK: - Recording

    func prewarmVoiceMode() {
        guard modelReady, !isRecording, !isStartingRecording, !isTranscribing else { return }
        setupAudioSession()
        _ = audioEngine.inputNode.inputFormat(forBus: 0)
        audioEngine.prepare()
        // Load the VAD model on app warmup so the first voice-mode
        // session doesn't pay the cold compile cost. The model file is
        // tiny (~900 KB) and compiles in well under 100 ms on A19 Pro.
        SileroVAD.shared.loadIfNeeded()
    }

    /// Runs the WhisperKit transcription graph once against a buffer of silence so
    /// the user's first real recording doesn't pay the cold compile cost. Result
    /// is discarded. Safe to call once after `loadModel()` completes.
    func prewarmTranscription() async {
        guard modelReady, let whisper = whisperKit else { return }
        // 0.5s of silence at 16 kHz — Whisper's native input rate.
        let silentSamples = [Float](repeating: 0, count: 8_000)
        do {
            _ = try await whisper.transcribe(
                audioArray: silentSamples,
                decodeOptions: Self.tunedDecodingOptions
            )
        } catch {
            print("⚠️ Whisper prewarm failed:", error.localizedDescription)
        }
    }

    func startRecording() {
        guard !isRecording else { return }

#if targetEnvironment(macCatalyst)
        // On Mac, starting the audio engine does NOT reliably trigger the
        // microphone permission prompt the way it does on iOS. Request it
        // explicitly: if undetermined, show the prompt and retry once granted;
        // if denied, bail with a clear log. iPhone path is unchanged (this
        // whole block compiles out there).
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .denied:
            print("❌ WhisperManager: microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.")
            isStartingRecording = false
            return
        case .undetermined:
            isStartingRecording = false
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor in
                    if granted {
                        self.startRecording()
                    } else {
                        print("❌ WhisperManager: microphone permission was not granted.")
                    }
                }
            }
            return
        @unknown default:
            break
        }
#endif

        isStartingRecording = true
        recordedSamples = []
        // Mute is STICKY — deliberately not reset here. If the user tapped
        // mute while listening, it stays muted across the AI's reply and
        // back into the next listening cycle. The only way mute clears is
        // an explicit tap (in ContentView's onToggleMicMute) or a fresh
        // voice-mode entry (handlePTTTap case .idle resets it).
        vadInputBuffer.removeAll(keepingCapacity: true)
        SileroVAD.shared.resetState()
        SileroVAD.shared.loadIfNeeded()
        lastRecordingDuration = 0
        lastSpeechActivityAt = nil
        lastSoundActivityAt = nil
        lastAudioActivityAt = nil
        liveTranscript = ""
        bestLiveTranscript = ""
        bestRawLiveTranscript = ""

        // Bluetooth headsets can switch the hardware input to 16-24 kHz.
        // Configure the session before reading the hardware format, then install
        // the tap with that exact format so Core Audio doesn't keep a stale 48 kHz tap.
        setupAudioSession()

        let inputNode = audioEngine.inputNode
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.reset()
        inputNode.removeTap(onBus: 0)

        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        nativeSampleRate = hardwareFormat.sampleRate

        // On macOS the input format can come back as 0 Hz / 0 channels until
        // microphone permission is granted or a real input device is bound.
        // Installing a tap with that format crashes Core Audio, so bail out
        // cleanly here — the next startRecording() (after permission/device is
        // ready) will install the tap properly.
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            isStartingRecording = false
            recordingStartedAt  = nil
            print("⚠️ WhisperManager: input format not ready (\(hardwareFormat.sampleRate) Hz, \(hardwareFormat.channelCount) ch) — mic permission or device pending.")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let count   = Int(buffer.frameLength)
            guard count > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: data, count: count))

            // RMS amplitude for orb animation
            var rms: Float = 0
            vDSP_measqv(samples, 1, &rms, vDSP_Length(count))
            let level = min(sqrt(rms) / 0.05, 1.0)

            let bufferSampleRate = buffer.format.sampleRate

            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isMicMuted {
                    // Drop the audio on the floor and zero the level so the orb
                    // visualization stays still — clear feedback that mic is off.
                    self.audioLevel = 0
                    return
                }
                self.audioLevel       = level
                self.nativeSampleRate = bufferSampleRate
                self.recordedSamples += samples
                self.observeRawAudioLevel(level)

                // Neural VAD: accumulate samples, resample to 16 kHz,
                // score model-sized chunks. It complements the raw RMS fallback
                // above so autosend has both a speech model and a direct mic
                // activity signal.
                self.feedVADAndUpdateActivity(samples, sourceRate: bufferSampleRate)
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording         = true
            isStartingRecording = false
            recordingStartedAt  = Date()
            print("✅ WhisperManager: recording started")
            startLiveTranscriptionTimer()
        } catch {
            isStartingRecording = false
            recordingStartedAt  = nil
            print("❌ WhisperManager: audio engine failed:", error)
        }
    }

    // MARK: - Live transcription timer

    private func startLiveTranscriptionTimer() {
        liveTimer?.invalidate()
        // Keep the first pass quick so voice mode feels live as soon as the orb opens.
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.runLiveTranscriptionPass()
            }
        }
    }

    private func runLiveTranscriptionPass() async {
        guard !isRunningLivePass, isRecording, let whisper = whisperKit else { return }
        let snapshot = recordedSamples
        guard snapshot.count > Int(nativeSampleRate * 0.5) else { return }  // need ≥ 0.5s audio

        isRunningLivePass = true
        defer { isRunningLivePass = false }

        let samples16k = resampleTo16k(snapshot, from: nativeSampleRate)
        do {
            let results = try await whisper.transcribe(
                audioArray: samples16k,
                decodeOptions: Self.tunedDecodingOptions
            )
            let text = results
                .compactMap { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                updateLiveTranscript(with: text)
            }
        } catch {
            // Silent — live passes are best-effort
        }
    }

    /// Stops recording, runs Whisper on the collected audio, returns the transcript.
    func stopAndTranscribe() async -> String {
        guard isRecording else { return "" }

        liveTimer?.invalidate()
        liveTimer = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        lastRecordingDuration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        isRecording    = false
        isTranscribing = true
        audioLevel     = 0
        lastSpeechActivityAt = nil
        lastSoundActivityAt = nil
        lastAudioActivityAt = nil

        defer {
            isTranscribing = false
            liveTranscript = ""
            bestLiveTranscript = ""
            bestRawLiveTranscript = ""
        }

        guard let whisper = whisperKit, !recordedSamples.isEmpty else {
            return ""
        }

        // WhisperKit requires 16 kHz mono float32
        let samples16k = resampleTo16k(recordedSamples, from: nativeSampleRate)

        do {
            let results = try await whisper.transcribe(
                audioArray: samples16k,
                decodeOptions: Self.tunedDecodingOptions
            )
            let text    = results
                .compactMap { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print("✅ WhisperKit transcript:", text)
            return text
        } catch {
            print("❌ WhisperKit transcription error:", error)
            return ""
        }
    }

    /// Stops recording without running the final Whisper pass. Used when the
    /// live transcript is stable enough to send immediately.
    func stopRecordingWithoutTranscribing() {
        liveTimer?.invalidate()
        liveTimer = nil
        guard isRecording else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        lastRecordingDuration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        isRecording     = false
        isTranscribing  = false
        audioLevel      = 0
        lastSpeechActivityAt = nil
        lastSoundActivityAt = nil
        lastAudioActivityAt = nil
        liveTranscript  = ""
        bestLiveTranscript = ""
        bestRawLiveTranscript = ""
        recordedSamples = []
    }

    func cancelRecording() {
        liveTimer?.invalidate()
        liveTimer = nil
        guard isRecording else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        recordingStartedAt = nil
        lastRecordingDuration = 0
        isRecording     = false
        isTranscribing  = false
        audioLevel      = 0
        lastSpeechActivityAt = nil
        lastSoundActivityAt = nil
        lastAudioActivityAt = nil
        liveTranscript  = ""
        bestLiveTranscript = ""
        bestRawLiveTranscript = ""
        recordedSamples = []
    }

    private func updateLiveTranscript(with rawText: String) {
        let candidate = Self.visibleTranscript(from: rawText)
        let rawCandidate = rawText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAmbientCue = Self.containsActionableAmbientCue(rawCandidate)
        guard !candidate.isEmpty || hasAmbientCue else { return }

        // Whisper live passes can regress after a pause. Keep the most complete
        // preview so the user can pause to think without watching prior words vanish.
        if candidate.count >= bestLiveTranscript.count || hasAmbientCue {
            bestLiveTranscript = candidate
            if rawCandidate.count >= bestRawLiveTranscript.count {
                bestRawLiveTranscript = rawCandidate
            }
            liveTranscript = bestRawLiveTranscript.isEmpty ? candidate : bestRawLiveTranscript
        }
    }

    static func containsActionableAmbientCue(_ transcript: String) -> Bool {
        let pattern = "(?:\\[([^\\]\\n]{1,48})\\]|\\(([^)\\n]{1,48})\\))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let nsText = transcript as NSString
        let matches = regex.matches(in: transcript, range: NSRange(location: 0, length: nsText.length))
        return matches.contains { match in
            let bracketRange = match.range(at: 1)
            let parenRange = match.numberOfRanges > 2 ? match.range(at: 2) : NSRange(location: NSNotFound, length: 0)
            let labelRange = bracketRange.location != NSNotFound ? bracketRange : parenRange
            guard labelRange.location != NSNotFound else { return false }
            return isActionableAmbientCueLabel(nsText.substring(with: labelRange))
        }
    }

    private static func isActionableAmbientCueLabel(_ rawLabel: String) -> Bool {
        // Normalise: lowercase, trim outer punctuation, then collapse
        // underscores/hyphens/extra whitespace into single spaces so
        // "[Blank_Audio]", "(blank-audio)", "[ BLANK AUDIO ]" all reduce to
        // "blank audio" before substring matching.
        let key = rawLabel
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]().,:;!?-_ \n\t"))
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        guard !key.isEmpty else { return false }
        let ignoredSilenceCues = [
            "silence",
            "silent",
            "pause",
            "paused",
            "quiet",
            "no speech",
            "no sound",
            "blank audio",
            "blank"
        ]
        return !ignoredSilenceCues.contains { key.contains($0) }
    }

    static func visibleTranscript(from rawText: String) -> String {
        rawText
            .replacingOccurrences(
                of: "(?:\\[[^\\]\\n]{1,48}\\]|\\([^)\\n]{1,48}\\))",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Audio session

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // Idempotent — the voice-mode session has already been locked
        // at entry by `SpeechManager.lockVoiceModeSession`. Only call
        // setCategory / setActive again if iOS has somehow flipped the
        // session out from under us. Each redundant call is a routing
        // re-evaluation that produces the volume-HUD blip the user
        // hears between turns.
        let needsCategory = session.category != .playAndRecord || session.mode != .default
        if needsCategory {
#if !targetEnvironment(macCatalyst)
            try? session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
#else
            try? session.setCategory(.playAndRecord, mode: .default, options: [])
#endif
            try? session.setActive(true, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Resampling (linear interpolation)

    private func observeRawAudioLevel(_ level: Float) {
        let now = Date()
        let speechRecently = lastSpeechActivityAt.map { now.timeIntervalSince($0) < 1.0 } ?? false
        if !speechRecently {
            updateAdaptiveNoiseFloor(with: level)
        }

        let soundThreshold = max(
            minimumSoundActivityLevel,
            adaptiveNoiseFloor + soundActivityNoiseMargin
        )
        if level >= soundThreshold {
            lastSoundActivityAt = now
        }
    }

    private func updateAdaptiveNoiseFloor(with level: Float) {
        let clampedLevel = min(max(level, 0), noiseFloorMaxLevel)
        let smoothing = clampedLevel > adaptiveNoiseFloor
            ? noiseFloorRiseSmoothing
            : noiseFloorFallSmoothing
        adaptiveNoiseFloor += (clampedLevel - adaptiveNoiseFloor) * smoothing
    }

    /// Append raw native-rate samples to the VAD input buffer, and any
    /// time we have enough for one model-sized chunk at 16 kHz, resample and
    /// score it. A VAD probability above `vadSpeechThreshold` updates
    /// `lastSpeechActivityAt` — that's the primary endpointing signal.
    private func feedVADAndUpdateActivity(_ samples: [Float], sourceRate: Double) {
        // Stay quiet when muted — no point burning inference cycles.
        guard !isMicMuted else { return }
        // Append to the rolling native-rate buffer.
        vadInputBuffer.append(contentsOf: samples)

        // One VAD chunk = 36 ms at 16 kHz = 576 samples post-resample.
        // The corresponding native count is the same duration at source rate.
        let nativePerChunk = max(1, Int(sourceRate * Double(SileroVAD.chunkSampleCount) / SileroVAD.sampleRate))

        while vadInputBuffer.count >= nativePerChunk {
            let nativeChunk = Array(vadInputBuffer.prefix(nativePerChunk))
            vadInputBuffer.removeFirst(nativePerChunk)

            // Resample → 16 kHz, force-truncate or pad to the model's exact input size.
            var resampled = resampleTo16k(nativeChunk, from: sourceRate)
            if resampled.count > SileroVAD.chunkSampleCount {
                resampled = Array(resampled.prefix(SileroVAD.chunkSampleCount))
            } else if resampled.count < SileroVAD.chunkSampleCount {
                resampled += Array(repeating: 0, count: SileroVAD.chunkSampleCount - resampled.count)
            }

            if let prob = SileroVAD.shared.score(chunk: resampled) {
                vadDiagnostic.observe(prob: prob, threshold: vadSpeechThreshold)
                if prob >= vadSpeechThreshold {
                    let now = Date()
                    lastSpeechActivityAt = now
                    lastAudioActivityAt = now
                }
            } else {
                vadDiagnostic.observeMissingScore()
            }
        }

        // Don't let the buffer grow unbounded if something hangs.
        if vadInputBuffer.count > nativePerChunk * 4 {
            vadInputBuffer.removeFirst(vadInputBuffer.count - nativePerChunk * 4)
        }
    }

    /// Lightweight per-second VAD telemetry. Prints peak score, average
    /// score, the configured threshold, and the % of chunks that scored
    /// above it. Lets you tell at a glance whether VAD is reading your
    /// voice (peak ~0.9+) or barely registering (peak ~0.4).
    struct VADDiagnostic {
        var verbose = false
        private var windowStart: Date = Date()
        private var samples: [Float] = []
        private var missing = 0

        mutating func observe(prob: Float, threshold: Float) {
            samples.append(prob)
            if verbose {
                print("VAD prob=\(String(format: "%.2f", prob)) thr=\(threshold)")
            }
            flushIfDue(threshold: threshold)
        }
        mutating func observeMissingScore() {
            missing += 1
            flushIfDue(threshold: 0.0)
        }
        private mutating func flushIfDue(threshold: Float) {
            guard Date().timeIntervalSince(windowStart) >= 1.0 else { return }
            let total  = samples.count
            let peak   = samples.max() ?? 0
            let avg    = samples.isEmpty ? 0 : samples.reduce(0, +) / Float(samples.count)
            let active = samples.filter { $0 >= threshold }.count
            let pct    = total > 0 ? Int(100 * Double(active) / Double(total)) : 0
            print("🧠 VAD/s: peak=\(String(format: "%.2f", peak)) avg=\(String(format: "%.2f", avg)) thr=\(threshold) above=\(pct)% (\(active)/\(total)) missing=\(missing)")
            samples.removeAll(keepingCapacity: true)
            missing = 0
            windowStart = Date()
        }
    }

    private func resampleTo16k(_ samples: [Float], from inputRate: Double) -> [Float] {
        let targetRate: Double = 16_000
        guard inputRate != targetRate, !samples.isEmpty else { return samples }

        let ratio        = targetRate / inputRate
        let outputLength = Int(Double(samples.count) * ratio)
        var output       = [Float](repeating: 0, count: outputLength)

        for i in 0 ..< outputLength {
            let srcPos = Double(i) / ratio
            let srcIdx = Int(srcPos)
            let frac   = Float(srcPos - Double(srcIdx))
            let s0     = srcIdx     < samples.count ? samples[srcIdx]     : 0
            let s1     = srcIdx + 1 < samples.count ? samples[srcIdx + 1] : 0
            output[i]  = s0 + frac * (s1 - s0)
        }
        return output
    }
}
