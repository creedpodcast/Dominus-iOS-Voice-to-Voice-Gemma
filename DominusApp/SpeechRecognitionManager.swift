import Foundation
import Combine
import Speech
import AVFoundation

@MainActor
final class SpeechRecognitionManager: NSObject, ObservableObject {

    static let shared = SpeechRecognitionManager()

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    @Published var transcript: String = ""
    @Published var isListening: Bool = false

    // ✅ Required for continuous loop:
    // silence ends the turn so it can auto-send
    @Published var autoStopOnSilence: Bool = true

    private var silenceTimer: Timer?
    private var lastTranscriptSnapshot: String = ""
    private let silenceSeconds: TimeInterval = 0.9

    override init() {
        super.init()
        requestPermissions()
    }

    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { status in
            print("🧠 Speech auth:", status.rawValue)
        }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            print("🎤 Mic permission:", granted)
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.autoStopOnSilence else { return }

            let current = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let snapshot = self.lastTranscriptSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)

            if self.isListening && !current.isEmpty && current == snapshot {
                self.stopListening()
            }
        }
    }

    func startListening() throws {
        stopListening()
        transcript = ""

        silenceTimer?.invalidate()
        silenceTimer = nil
        lastTranscriptSnapshot = ""

        guard let recognizer = speechRecognizer else {
            print("❌ speechRecognizer is nil")
            return
        }
        guard recognizer.isAvailable else {
            print("❌ speechRecognizer not available")
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .duckOthers]
            )

            if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtInMic)
            }

            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("❌ AVAudioSession setup error:", error)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                self.transcript = text

                if self.autoStopOnSilence {
                    self.lastTranscriptSnapshot = text
                    self.resetSilenceTimer()
                }
            }

            if let error = error {
                print("❌ recognitionTask error:", error)
                self.stopListening()
                return
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("❌ audioEngine.start() failed:", error)
            stopListening()
            return
        }

        isListening = true
        print("✅ Listening started")
    }

    func stopListening() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        isListening = false

        silenceTimer?.invalidate()
        silenceTimer = nil
        lastTranscriptSnapshot = ""

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("⚠️ AVAudioSession deactivate error:", error)
        }

        print("🛑 Listening stopped")
    }
}
