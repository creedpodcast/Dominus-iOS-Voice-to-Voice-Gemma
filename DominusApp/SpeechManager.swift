import AVFoundation
import FluidAudio

@MainActor
final class SpeechManager: NSObject, AVAudioPlayerDelegate {

    static let shared = SpeechManager()

    private let tts = KokoroTtsManager(defaultVoice: "af_heart")
    private var isInitialized = false
    private var queue: [String] = []
    private var isProcessing = false
    private var currentTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?

    var onAllSpeechFinished: (() -> Void)?

    override init() {
        super.init()
        Task { await self.setupTTS() }
    }

    private func setupTTS() async {
        do {
            try await tts.initialize()
            isInitialized = true
            print("🎙 Kokoro TTS ready")
        } catch {
            print("🎙 Kokoro TTS init error:", error)
        }
    }

    func enqueue(_ text: String) {
        let cleaned = clean(text)
        guard !cleaned.isEmpty else { return }
        queue.append(cleaned)
        startIfNeeded()
    }

    func stopAndClear() {
        queue.removeAll()
        isProcessing = false
        currentTask?.cancel()
        currentTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
    }

    private func startIfNeeded() {
        guard !isProcessing, !queue.isEmpty else { return }
        isProcessing = true
        synthesizeAndPlay(queue.removeFirst())
    }

    private func synthesizeAndPlay(_ text: String) {
        currentTask = Task {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true)

                let wavData = try await tts.synthesize(text: text)
                guard !Task.isCancelled else { return }

                let player = try AVAudioPlayer(data: wavData)
                player.delegate = self
                self.audioPlayer = player
                player.prepareToPlay()
                player.play()
            } catch {
                guard !Task.isCancelled else { return }
                print("🎙 Kokoro synthesis error:", error)
                playNext()
            }
        }
    }

    private func playNext() {
        guard !queue.isEmpty else {
            isProcessing = false
            onAllSpeechFinished?()
            return
        }
        synthesizeAndPlay(queue.removeFirst())
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playNext() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.playNext() }
    }

    // MARK: - Clean

    private func clean(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "```", with: "")
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
}
