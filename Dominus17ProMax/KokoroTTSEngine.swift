import AVFoundation
import Accelerate
import Foundation

#if canImport(Kokoro)
import Kokoro
#endif

/// On-device Kokoro-82M TTS backend. Mirrors the slice of `SpeechManager`'s
/// public surface that the rest of the app actually calls — `enqueue`,
/// `stopAndClear`, `isSpeaking`, `onAllSpeechFinished` — so `SpeechManager`
/// can route to either backend behind a single flag.
///
/// Synthesis is non-streaming: Kokoro produces a whole utterance's worth of
/// 24 kHz PCM samples and we play them through the same `AVAudioEngine`
/// chain used for AVSpeech buffers. Per-utterance work runs in a serial
/// `Task` so multiple `enqueue` calls play in order.
///
/// Audio session is NOT touched here — `SpeechRecognitionManager` owns it
/// (per CLAUDE.md). We assume `.playAndRecord` is already active.
@MainActor
final class KokoroTTSEngine: ObservableObject {

    static let shared = KokoroTTSEngine()

    /// Fires when every queued utterance has finished playing. Kept identical
    /// to SpeechManager's hook so ContentView's resume-listening logic works
    /// unchanged.
    var onAllSpeechFinished: (() -> Void)?

    @Published private(set) var isSpeaking: Bool = false
    @Published private(set) var isStartingPlayback: Bool = false
    @Published private(set) var ttsAmplitude: Float = 0

    /// True iff the Kokoro Swift package is linked AND the pipeline initialised
    /// (model files reachable). When false, callers should fall back to system TTS.
    var isAvailable: Bool { pipelineReady }

    // MARK: - Engine pipeline (mirrors SpeechManager)

    private let audioEngine = AVAudioEngine()
    private let playerNode  = AVAudioPlayerNode()
    private var engineFormat: AVAudioFormat?
    private var engineConfigured = false

    /// 24 kHz mono Float32 — Kokoro's output format.
    private let kokoroSampleRate: Double = 24_000

    // MARK: - Queue

    private struct QueuedUtterance {
        let id: UUID
        let text: String
        let voice: String
    }

    private var queue: [QueuedUtterance] = []
    private var currentTask: Task<Void, Never>?
    private var outstandingUtterances: Int = 0

    private var pipelineReady: Bool = false

    private init() {
        warmPipelineIfPossible()
    }

    // MARK: - Public API

    func prepareForVoiceMode() {
        warmPipelineIfPossible()
    }

    func prewarmVoice() {
        warmPipelineIfPossible()
    }

    func enqueue(_ text: String, voice: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard pipelineReady else { return }

        outstandingUtterances += 1
        isSpeaking = true
        queue.append(QueuedUtterance(id: UUID(), text: trimmed, voice: voice))
        startDrainIfIdle()
    }

    func stopAndClear() {
        currentTask?.cancel()
        currentTask = nil
        queue.removeAll()
        outstandingUtterances = 0
        isSpeaking = false
        isStartingPlayback = false
        ttsAmplitude = 0
        if playerNode.isPlaying { playerNode.stop() }
    }

    // MARK: - Drain loop

    private func startDrainIfIdle() {
        guard currentTask == nil else { return }
        currentTask = Task { @MainActor [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        defer { currentTask = nil }
        while !queue.isEmpty {
            if Task.isCancelled { return }
            let next = queue.removeFirst()
            isStartingPlayback = true
            await synthesizeAndPlay(next)
            isStartingPlayback = false
            if Task.isCancelled { return }
            handleUtteranceCompleted()
        }
    }

    private func handleUtteranceCompleted() {
        outstandingUtterances = max(0, outstandingUtterances - 1)
        if outstandingUtterances == 0 && queue.isEmpty {
            isSpeaking = false
            ttsAmplitude = 0
            onAllSpeechFinished?()
        }
    }

    // MARK: - Synthesis

    private func synthesizeAndPlay(_ utt: QueuedUtterance) async {
        #if canImport(Kokoro)
        guard let samples = await KokoroBridge.shared.synthesize(text: utt.text, voice: utt.voice) else {
            return
        }
        if Task.isCancelled { return }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: kokoroSampleRate,
            channels: 1,
            interleaved: false
        )
        guard let format,
              let buffer = makePCMBuffer(samples: samples, format: format) else { return }
        configureEngineIfNeeded(with: format)
        guard engineConfigured, audioEngine.isRunning else { return }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            playerNode.scheduleBuffer(
                buffer,
                at: nil,
                options: [],
                completionCallbackType: .dataPlayedBack
            ) { _ in
                cont.resume()
            }
            if !playerNode.isPlaying { playerNode.play() }
        }
        #else
        _ = utt
        return
        #endif
    }

    private func makePCMBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let dst = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            dst.update(from: base, count: samples.count)
        }
        return buffer
    }

    // MARK: - Engine setup (peak limiter + amplitude tap, same as SpeechManager)

    private func configureEngineIfNeeded(with format: AVAudioFormat) {
        if engineConfigured {
            if audioEngine.isRunning { return }
            try? audioEngine.start()
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
        let limiter = AVAudioUnitEffect(audioComponentDescription: limiterDesc)
        audioEngine.attach(playerNode)
        audioEngine.attach(limiter)
        audioEngine.connect(playerNode, to: limiter, format: format)
        audioEngine.connect(limiter, to: audioEngine.mainMixerNode, format: format)

        let outputFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
        audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: outputFormat) { [weak self] buffer, _ in
            guard let self,
                  let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var meanSquare: Float = 0
            vDSP_measqv(ch, 1, &meanSquare, vDSP_Length(n))
            let rms = sqrt(meanSquare)
            let raw = min(rms * 4.5, 1.0)
            Task { @MainActor [weak self] in
                self?.ttsAmplitude = max(raw, (self?.ttsAmplitude ?? 0) * 0.85)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            engineConfigured = true
        } catch {
            print("❌ Kokoro engine start failed:", error.localizedDescription)
        }
    }

    // MARK: - Pipeline lazy init

    private func warmPipelineIfPossible() {
        #if canImport(Kokoro)
        Task { @MainActor in
            pipelineReady = await KokoroBridge.shared.ensureReady()
        }
        #else
        pipelineReady = false
        #endif
    }
}

#if canImport(Kokoro)

/// Thin async-safe shim around `KPipeline`. Lives outside the @MainActor
/// engine so model loading and synthesis can happen off the main thread.
actor KokoroBridge {
    static let shared = KokoroBridge()

    private var pipeline: KPipeline?
    private var loader: VoiceLoader?
    private var didFailInit = false

    func ensureReady() async -> Bool {
        if pipeline != nil { return true }
        if didFailInit { return false }
        do {
            let baseDir = Self.voicesDirectory()
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            let loader = VoiceLoader(baseDirectory: baseDir, enableDownload: true)
            // CoreML backend uses the Apple Neural Engine. If you'd rather force
            // MLX (GPU), swap SegmentedCoreMLModel for KModel here.
            let model = try await SegmentedCoreMLModel()
            let pipeline = try await KPipeline(model: model, voiceLoader: loader)
            self.loader = loader
            self.pipeline = pipeline
            return true
        } catch {
            print("❌ Kokoro init failed:", error.localizedDescription)
            didFailInit = true
            return false
        }
    }

    func synthesize(text: String, voice: String) async -> [Float]? {
        guard let pipeline else { return nil }
        do {
            let result = try await pipeline.synthesize(text: text, voice: voice)
            return result.samples
        } catch {
            print("❌ Kokoro synthesize failed:", error.localizedDescription)
            return nil
        }
    }

    private static func voicesDirectory() -> URL {
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return (support ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("KokoroVoices", isDirectory: true)
    }
}

#endif
