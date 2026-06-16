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
    @Published var lastAudioActivityAt: Date?

    // MARK: - Private

    private var whisperKit:      WhisperKit?
    private let audioEngine    = AVAudioEngine()
    private var recordedSamples: [Float]  = []
    private var nativeSampleRate: Double  = 44_100
    private var recordingStartedAt: Date?
    private var bestLiveTranscript: String = ""
    private var bestRawLiveTranscript: String = ""
    private let voiceActivityLevelThreshold: Float = 0.035

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
    }

    /// Runs the WhisperKit transcription graph once against a buffer of silence so
    /// the user's first real recording doesn't pay the cold compile cost. Result
    /// is discarded. Safe to call once after `loadModel()` completes.
    func prewarmTranscription() async {
        guard modelReady, let whisper = whisperKit else { return }
        // 0.5s of silence at 16 kHz — Whisper's native input rate.
        let silentSamples = [Float](repeating: 0, count: 8_000)
        do {
            _ = try await whisper.transcribe(audioArray: silentSamples)
        } catch {
            print("⚠️ Whisper prewarm failed:", error.localizedDescription)
        }
    }

    func startRecording() {
        guard !isRecording else { return }
        isStartingRecording = true
        recordedSamples = []
        isMicMuted = false   // every fresh recording cycle starts unmuted
        lastRecordingDuration = 0
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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let count   = Int(buffer.frameLength)
            guard count > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: data, count: count))

            // RMS amplitude for orb animation
            var rms: Float = 0
            vDSP_measqv(samples, 1, &rms, vDSP_Length(count))
            let level = min(sqrt(rms) / 0.05, 1.0)

            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isMicMuted {
                    // Drop the audio on the floor and zero the level so the orb
                    // visualization stays still — clear feedback that mic is off.
                    self.audioLevel = 0
                    return
                }
                self.audioLevel       = level
                if level >= self.voiceActivityLevelThreshold {
                    self.lastAudioActivityAt = Date()
                }
                self.nativeSampleRate = buffer.format.sampleRate
                self.recordedSamples += samples
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
            let results = try await whisper.transcribe(audioArray: samples16k)
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
            let results = try await whisper.transcribe(audioArray: samples16k)
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
        let key = rawLabel
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]().,:;!?-_ \n\t"))

        guard !key.isEmpty else { return false }
        let ignoredSilenceCues = [
            "silence",
            "silent",
            "pause",
            "paused",
            "quiet",
            "no speech",
            "no sound",
            "blank audio"
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
        try? session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Resampling (linear interpolation)

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
