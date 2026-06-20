import CoreML
import Foundation

/// Neural Voice Activity Detection using Silero VAD v6, run on Core ML / ANE.
///
/// This replaces the previous fixed-RMS-threshold "is the user speaking?"
/// signal with a model-based one. Silero is the industry-standard VAD used
/// in ChatGPT voice, Pi, faster-whisper, and most production voice
/// assistants. It distinguishes real speech from fans, traffic, music,
/// TVs, typing, and most ambient room noise at ~98% accuracy across
/// languages, and runs in under 1 ms per 36 ms audio chunk on Apple
/// Silicon.
///
/// API contract (matches the .mlpackage we bundle in the app):
/// - `audio_input`  — 576 Float samples at 16 kHz (= one 36 ms chunk)
/// - `hidden_state` — LSTM hidden, shape [2, 1, 64], initially zeros
/// - `cell_state`   — LSTM cell,   shape [2, 1, 64], initially zeros
/// - Outputs: `vad_output` (Float, [1, 1]) plus `new_hidden_state` and
///   `new_cell_state` to feed back into the next call.
/// Not `@MainActor` — the audio tap callback (a background, real-time
/// priority thread) is the only caller of `score(chunk:)` during a
/// voice-mode session. Keeping inference off the main actor avoids
/// stealing CPU from SwiftUI updates. The internal LSTM state is only
/// mutated by that one thread, so no lock is needed.
final class SileroVAD {

    static let shared = SileroVAD()

    /// Required audio chunk size for one inference call. This Core ML
    /// conversion expects 576 samples at 16 kHz; feeding the more common
    /// 512-sample Silero frame makes every prediction fail with a shape error.
    static let chunkSampleCount = 576
    static let sampleRate: Double = 16_000

    private var model: MLModel?
    private var loadFailed = false

    // LSTM state shape from the Silero v6 contract. We reset this each
    // time voice mode opens so the model starts fresh.
    // Rank-2 `[1, 128]` — the FluidInference Core ML conversion flattens
    // the LSTM state across layers (2 layers × 64 hidden = 128) into a
    // single batch row. Confirmed by the runtime error
    // "MultiArray shape (2 x 64) does not match the shape (1 x 128)
    // specified in the model description". Passing any other shape
    // makes every inference call fail silently and `score(chunk:)`
    // returns nil — which means `lastAudioActivityAt` is never updated
    // and the autosend timer has no speech signal to gate on.
    private static let stateShape: [NSNumber] = [1, 128]
    private var hiddenState: MLMultiArray?
    private var cellState: MLMultiArray?

    private init() {}

    /// True once the model has been compiled and is ready to score chunks.
    var isReady: Bool { model != nil && !loadFailed }

    /// Lazy load the bundled model. Called once on first VAD scoring; safe
    /// to call repeatedly (no-op after success).
    func loadIfNeeded() {
        guard model == nil, !loadFailed else { return }
        // The Core ML model file is bundled as SileroVADModel.mlpackage to
        // avoid a Swift class-name collision: Xcode auto-generates a class
        // named after the .mlpackage file, so naming the file SileroVAD
        // would collide with this wrapper. Xcode compiles .mlpackage →
        // .mlmodelc at build time; we prefer the compiled form when
        // available.
        guard let url = Bundle.main.url(forResource: "SileroVADModel", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "SileroVADModel", withExtension: "mlpackage") else {
            print("🔇 SileroVAD: model file not found in bundle (expected SileroVADModel.mlmodelc/mlpackage)")
            loadFailed = true
            return
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all   // Neural Engine when available
        do {
            self.model = try MLModel(contentsOf: url, configuration: config)
            resetState()
        } catch {
            print("🔇 SileroVAD: model load failed —", error.localizedDescription)
            loadFailed = true
        }
    }

    /// Wipe LSTM state. Call when starting a new voice-mode session so
    /// the model doesn't carry stale context from the previous session.
    func resetState() {
        hiddenState = Self.makeZeroState()
        cellState   = Self.makeZeroState()
    }

    /// Score one 36 ms chunk of mono Float audio at 16 kHz.
    /// Returns speech probability in [0, 1], or nil if the model isn't ready
    /// or the chunk is the wrong size. Callers should compare against a
    /// threshold (~0.5 for permissive, ~0.7 for strict).
    func score(chunk: [Float]) -> Float? {
        loadIfNeeded()
        guard let model,
              let hiddenState,
              let cellState else { return nil }
        guard chunk.count == Self.chunkSampleCount else { return nil }

        guard let audio = try? MLMultiArray(
            shape: [1, NSNumber(value: chunk.count)],
            dataType: .float32
        ) else { return nil }

        chunk.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            audio.dataPointer
                .bindMemory(to: Float.self, capacity: chunk.count)
                .update(from: base, count: chunk.count)
        }

        let provider: MLDictionaryFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input":  MLFeatureValue(multiArray: audio),
                "hidden_state": MLFeatureValue(multiArray: hiddenState),
                "cell_state":   MLFeatureValue(multiArray: cellState)
            ])
        } catch {
            return nil
        }

        guard let result = try? model.prediction(from: provider) else { return nil }

        // Carry the new LSTM state forward so the next call has context.
        if let newHidden = result.featureValue(for: "new_hidden_state")?.multiArrayValue {
            self.hiddenState = newHidden
        }
        if let newCell = result.featureValue(for: "new_cell_state")?.multiArrayValue {
            self.cellState = newCell
        }

        guard let out = result.featureValue(for: "vad_output")?.multiArrayValue,
              out.count >= 1 else { return nil }
        return out[0].floatValue
    }

    private static func makeZeroState() -> MLMultiArray? {
        guard let arr = try? MLMultiArray(shape: stateShape, dataType: .float32) else { return nil }
        let count = arr.count
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: count)
        ptr.update(repeating: 0, count: count)
        return arr
    }
}
