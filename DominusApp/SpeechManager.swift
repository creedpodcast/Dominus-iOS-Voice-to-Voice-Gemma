// SpeechManager.swift — Kokoro-82M on-device TTS (fully local, no internet)
// Pipelined: next chunk is synthesized while current chunk is playing.

import AVFoundation
import Combine

@MainActor
final class SpeechManager: NSObject, AVAudioPlayerDelegate {

    static let shared = SpeechManager()

    // am_michael = 6, am_adam = 5, bm_george = 9 (British Male)
    private let voiceSID: Int = 6
    private let voiceSpeed: Float = 1.0

    @Published var isSpeaking: Bool = false
    var onAllSpeechFinished: (() -> Void)?

    private var tts: SherpaOnnxOfflineTtsWrapper?
    private var queue: [String] = []
    private var prefetchedURL: URL? = nil   // next chunk synthesized ahead
    private var isSynthesizing = false
    private var isPlaying = false
    private var player: AVAudioPlayer?

    private let synthQueue = DispatchQueue(label: "dominus.kokoro", qos: .userInitiated)

    private override init() {
        super.init()
        tts = makeTTS()
        if tts == nil {
            print("⚠️ Kokoro: model not found in bundle. Add DominusApp/kokoro folder to Xcode target.")
        } else {
            print("🗣 Kokoro-82M ready (fully local, am_michael)")
        }
    }

    // MARK: - Public API

    func enqueue(_ text: String) {
        let cleaned = clean(text)
        guard !cleaned.isEmpty else { return }
        queue.append(cleaned)
        pumpPipeline()
    }

    func stopAndClear() {
        queue.removeAll()
        prefetchedURL = nil
        isSynthesizing = false
        isPlaying = false
        isSpeaking = false
        player?.stop()
        player = nil
    }

    // MARK: - Pipeline

    /// Drive the two-stage pipeline: synthesize ahead, play when ready.
    private func pumpPipeline() {
        // Stage 1: if nothing is being synthesized and queue has work, start synthesizing
        if !isSynthesizing && !queue.isEmpty && prefetchedURL == nil {
            synthesizeNext()
        }
        // Stage 2: if not playing and a prefetched chunk is ready, play it
        if !isPlaying, let url = prefetchedURL {
            prefetchedURL = nil
            playURL(url)
        }
    }

    private func synthesizeNext() {
        guard let tts, !queue.isEmpty else { return }
        isSynthesizing = true
        let chunk = queue.removeFirst()
        let sid = voiceSID
        let speed = voiceSpeed

        synthQueue.async { [weak self] in
            guard let self else { return }
            let audio = tts.generate(text: chunk, sid: sid, speed: speed)
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".wav")
            let saved = audio.save(filename: tmpURL.path)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSynthesizing = false
                if saved == 1 {
                    self.prefetchedURL = tmpURL
                }
                self.pumpPipeline()
            }
        }
    }

    private func playURL(_ url: URL) {
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.play()
            isPlaying = true
            isSpeaking = true
            // Start synthesizing the next chunk immediately while this one plays
            pumpPipeline()
        } catch {
            print("⚠️ Kokoro playback error:", error)
            chunkFinished()
        }
    }

    private func chunkFinished() {
        isPlaying = false
        if queue.isEmpty && prefetchedURL == nil && !isSynthesizing {
            isSpeaking = false
            onAllSpeechFinished?()
        } else {
            pumpPipeline()
        }
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.chunkFinished() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("⚠️ Kokoro decode error:", error ?? "unknown")
        Task { @MainActor [weak self] in self?.chunkFinished() }
    }

    // MARK: - Engine setup

    private func makeTTS() -> SherpaOnnxOfflineTtsWrapper? {
        guard let modelDir = Bundle.main.path(forResource: "kokoro", ofType: nil) else {
            return nil
        }
        let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
            model:   modelDir + "/model.onnx",
            voices:  modelDir + "/voices.bin",
            tokens:  modelDir + "/tokens.txt",
            dataDir: modelDir + "/espeak-ng-data"
        )
        let modelConfig = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: 4, debug: 0)
        var config = sherpaOnnxOfflineTtsConfig(model: modelConfig)
        return SherpaOnnxOfflineTtsWrapper(config: &config)
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
}
