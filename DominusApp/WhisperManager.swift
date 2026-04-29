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
/// `SpeechRecognitionManager` is NOT replaced — it still handles VAD amplitude
/// monitoring while the AI is speaking. WhisperManager only runs during the
/// user's recording window.
@MainActor
final class WhisperManager: ObservableObject {

    static let shared = WhisperManager()

    // MARK: - Published state

    @Published var isRecording:     Bool   = false
    @Published var isTranscribing:  Bool   = false
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

    // MARK: - Private

    private var whisperKit:      WhisperKit?
    private let audioEngine    = AVAudioEngine()
    private var recordedSamples: [Float]  = []
    private var nativeSampleRate: Double  = 44_100

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

    func startRecording() {
        guard !isRecording else { return }
        recordedSamples = []
        isMicMuted = false   // every fresh recording cycle starts unmuted

        let inputNode = audioEngine.inputNode
        let format    = inputNode.outputFormat(forBus: 0)
        nativeSampleRate = format.sampleRate

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let count   = Int(buffer.frameLength)
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
                self.recordedSamples += samples
            }
        }

        do {
            // Ensure audio session is active with echo-cancelling voiceChat mode.
            // Called here because SpeechRecognitionManager's session is torn down
            // before beginListening() hands off to WhisperManager.
            setupAudioSession()
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            print("✅ WhisperManager: recording started")
            startLiveTranscriptionTimer()
        } catch {
            print("❌ WhisperManager: audio engine failed:", error)
        }
    }

    // MARK: - Live transcription timer

    private func startLiveTranscriptionTimer() {
        liveTimer?.invalidate()
        // Wait 2 seconds before the first pass so there's enough audio to transcribe
        liveTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
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
                liveTranscript = text
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
        isRecording    = false
        isTranscribing = true
        audioLevel     = 0

        defer {
            isTranscribing = false
            liveTranscript = ""
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

    func cancelRecording() {
        liveTimer?.invalidate()
        liveTimer = nil
        guard isRecording else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        isRecording     = false
        isTranscribing  = false
        audioLevel      = 0
        liveTranscript  = ""
        recordedSamples = []
    }

    // MARK: - Audio session

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth]
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
