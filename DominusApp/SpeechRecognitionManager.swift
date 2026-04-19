import Foundation
import Combine
import Speech
import AVFoundation
import Accelerate

@MainActor
final class SpeechRecognitionManager: NSObject, ObservableObject {

    static let shared = SpeechRecognitionManager()

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine      = AVAudioEngine()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask:    SFSpeechRecognitionTask?

    @Published var transcript:       String = ""
    @Published var isListening:      Bool   = false
    @Published var autoStopOnSilence: Bool  = true

    // VAD — fires when user starts speaking while AI is talking
    var onVoiceActivityDetected: (() -> Void)?

    // Fires whenever STT stops for any reason — ContentView decides whether to restart
    var onSTTEnded: (() -> Void)?

    /// Enable to start monitoring mic amplitude for voice interrupt
    var monitorForVAD: Bool = false


    private var silenceTimer:         Timer?
    private var lastTranscriptSnapshot: String = ""
    private let silenceSeconds: TimeInterval   = 1.2

    // VAD thresholds — requires a few consecutive loud frames to avoid false triggers
    private var vadTriggerCount: Int  = 0
    private let vadThreshold:   Float = 0.018   // RMS amplitude
    private let vadFramesNeeded: Int  = 3        // consecutive frames before firing

    override init() {
        super.init()
        requestPermissions()
    }

    // MARK: - Unified voice session (call once per conversation session)

    /// Sets up a single shared audio session with echo cancellation.
    /// Call when the user starts a voice session. Do NOT call setCategory anywhere else.
    func setupVoiceSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,           // ← Built-in echo cancellation — AI won't hear itself
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        // Start the engine with a permanent tap — feeds STT + monitors amplitude for VAD
        startEngineIfNeeded()
        print("✅ Voice session active | echo cancellation ON")
    }

    /// Tears down the session completely. Call when user ends voice mode.
    func tearDownVoiceSession() {
        stopSTT()
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        monitorForVAD  = false
        vadTriggerCount = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        print("🛑 Voice session ended")
    }

    // MARK: - STT

    func startListening() throws {
        // Ensure session + engine are running (handles both session and non-session mode)
        if !audioEngine.isRunning {
            try setupVoiceSession()
        }

        stopSTT()
        transcript          = ""
        vadTriggerCount     = 0
        monitorForVAD       = false  // not needed — we're already recording

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("❌ SFSpeechRecognizer not available")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults  = true
        request.requiresOnDeviceRecognition = true   // fully on-device, no Apple servers
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.transcript = text
                    if self.autoStopOnSilence {
                        self.lastTranscriptSnapshot = text
                        self.resetSilenceTimer()
                    }
                }
            }
            if let error = error {
                let nsErr = error as NSError
                // 1110 = no speech, 216 = session ended, 203 = cancelled — all normal
                if nsErr.code != 1110 && nsErr.code != 216 && nsErr.code != 203 {
                    print("❌ STT error:", error.localizedDescription)
                }
                Task { @MainActor in
                    self.stopSTT()
                    // Notify ContentView so it can decide whether to restart
                    self.onSTTEnded?()
                }
            }
        }

        isListening = true
        print("✅ Listening started")
    }

    /// Stops STT but keeps the audio engine and mic tap running for VAD.
    func stopListening() {
        stopSTT()
        // Do NOT stop the engine or deactivate the session here —
        // it needs to stay alive for TTS and VAD monitoring.
    }

    // MARK: - Engine

    private func startEngineIfNeeded() {
        guard !audioEngine.isRunning else { return }

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)

        // Single permanent tap: feeds STT when active, always monitors amplitude
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)   // nil-safe: no-op when STT inactive
            self?.checkVAD(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            print("✅ Audio engine started")
        } catch {
            print("❌ Audio engine start failed:", error)
        }
    }

    // MARK: - VAD amplitude monitor

    private func checkVAD(_ buffer: AVAudioPCMBuffer) {
        guard monitorForVAD else { return }
        guard let data = buffer.floatChannelData?[0] else { return }
        let length = vDSP_Length(buffer.frameLength)
        guard length > 0 else { return }

        var rms: Float = 0
        vDSP_measqv(data, 1, &rms, length)
        rms = sqrt(rms)

        if rms > vadThreshold {
            vadTriggerCount += 1
            if vadTriggerCount >= vadFramesNeeded {
                vadTriggerCount = 0
                Task { @MainActor [weak self] in
                    guard let self, self.monitorForVAD else { return }
                    self.monitorForVAD = false   // prevent double-fire
                    self.onVoiceActivityDetected?()
                }
            }
        } else {
            if vadTriggerCount > 0 { vadTriggerCount -= 1 }
        }
    }

    // MARK: - Silence timer

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: silenceSeconds,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            guard self.autoStopOnSilence, self.isListening else { return }
            let current  = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let snapshot = self.lastTranscriptSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
            if !current.isEmpty && current == snapshot {
                self.stopSTT()
            }
        }
    }

    // MARK: - Internal helpers

    private func stopSTT() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest    = nil
        recognitionTask       = nil
        isListening           = false
        silenceTimer?.invalidate()
        silenceTimer          = nil
        lastTranscriptSnapshot = ""
        print("🛑 STT stopped")
    }

    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { status in
            print("🧠 Speech auth:", status.rawValue)
        }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            print("🎤 Mic permission:", granted)
        }
    }
}
