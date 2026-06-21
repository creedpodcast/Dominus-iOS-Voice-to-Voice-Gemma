import Foundation
import Combine
import SwiftLlama

@MainActor
final class GemmaEngine: ObservableObject {
    @Published var isLoaded: Bool = false
    @Published var isLoading: Bool = false
    @Published var loadProgress: Double = 0.0
    @Published var loadStatus: String = "Idle"

    private var llama: LlamaService?
    private var progressTask: Task<Void, Never>?

    /// Lightweight, tokenization-only model handle. Loaded with default params
    /// (n_gpu_layers = 0, mmap), so it shares the GGUF's read-only pages with the
    /// inference instance instead of duplicating ~1.6 GB. Used purely to count the
    /// exact tokens of an assembled prompt so context assembly can stay under the
    /// real window. nil until the inference model has loaded (backend init).
    private var tokenizer: LlamaModel?

    private let modelResourceName: String = "gemma-2-2b-it-Q4_K_M"
    private let modelExtension: String = "gguf"

    private let batchSize: UInt32 = 512
    // Context window (n_ctx). Gemma 2 trained at 8192; 4096 gives the budgeted
    // prompt assembly real headroom while staying cheap on KV cache (~208 MiB).
    // Per-token/prefill cost scales with the ACTUAL tokens used, not this cap,
    // so raising it does not slow ordinary turns.
    private let maxTokenCount: UInt32 = 4096
    private let useGPU: Bool = true

    /// The configured context window (n_ctx) in tokens.
    var contextWindow: Int { Int(maxTokenCount) }

    func loadModelIfNeeded() {
        guard !isLoaded, !isLoading else { return }

        isLoading = true
        isLoaded = false
        loadProgress = 0.0
        loadStatus = "Starting…"

        startStagedProgress()

        Task {
            defer {
                stopStagedProgress()
                isLoading = false
            }

            loadStatus = "Checking model…"
            guard let modelUrl = Bundle.main.url(forResource: modelResourceName, withExtension: modelExtension) else {
                loadStatus = "Model not found."
                loadProgress = 0.0
                return
            }

            if let attrs = try? FileManager.default.attributesOfItem(atPath: modelUrl.path),
               let fileSize = attrs[.size] as? NSNumber {
                let mb = Double(truncating: fileSize) / (1024.0 * 1024.0)
                loadStatus = String(format: "Model found (%.0f MB). Initializing…", mb)
            } else {
                loadStatus = "Model found. Initializing…"
            }

            llama = LlamaService(
                modelUrl: modelUrl,
                config: .init(
                    batchSize: batchSize,
                    maxTokenCount: maxTokenCount,
                    useGPU: useGPU
                )
            )

            loadStatus = "Ready."
            isLoaded = true
            loadProgress = 1.0
        }
    }

    /// Run a tiny throwaway generation so the very first user-facing turn doesn't
    /// pay the cold inference cost (graph JIT, KV cache init, accelerator warmup).
    /// Safe to call once after the model finishes loading.
    func prewarm() async {
        loadModelIfNeeded()
        // Wait briefly for the load Task to flip isLoaded — it dispatches into its own Task.
        for _ in 0..<200 {
            if isLoaded { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard isLoaded, let llama else { return }
        do {
            loadStatus = "Warming up…"
            let messages: [LlamaChatMessage] = [
                .init(role: .system, content: "ok"),
                .init(role: .user,   content: "ok")
            ]
            let stream = try await llama.streamCompletion(
                of: messages,
                samplingConfig: .init(temperature: 0.0, seed: 1)
            )
            var burned = 0
            for try await _ in stream {
                burned += 1
                if burned >= 2 { break }
            }
            loadStatus = "Ready."
        } catch {
            // Warmup failures are non-fatal — the real first turn will just pay the cost.
            print("⚠️ Gemma prewarm failed:", error.localizedDescription)
        }
    }

    func resetModel() {
        stopStagedProgress()
        llama = nil
        tokenizer = nil
        isLoaded = false
        isLoading = false
        loadProgress = 0.0
        loadStatus = "Idle"
    }

    /// Exact number of tokens the model will see for `messages`, including the
    /// chat template wrapping and BOS. Falls back to a conservative character
    /// estimate if the tokenizer is unavailable (e.g. model not yet loaded), so
    /// callers can always get a usable number without crashing.
    func tokenCount(for messages: [LlamaChatMessage]) -> Int {
        if let exact = exactTokenCount(for: messages) { return exact }
        // Fallback: ~4 chars/token is a rough lower bound; round UP and pad so
        // budget math stays conservative when we can't measure precisely.
        let chars = messages.reduce(0) { $0 + $1.content.count }
        return max(1, (chars / 3) + 8)
    }

    /// True exact count via the bundled tokenizer, or nil if it isn't ready.
    private func exactTokenCount(for messages: [LlamaChatMessage]) -> Int? {
        guard let model = ensureTokenizer() else { return nil }
        let prompt = model.applyChatTemplate(to: messages, addAssistant: true)
        return model.tokenize(text: prompt, addBos: model.shouldAddBos(), special: true).count
    }

    /// Lazily build the tokenization-only model. Only after the inference model
    /// has loaded, which guarantees the llama backend is initialized.
    private func ensureTokenizer() -> LlamaModel? {
        if let tokenizer { return tokenizer }
        guard isLoaded,
              let modelUrl = Bundle.main.url(forResource: modelResourceName, withExtension: modelExtension)
        else { return nil }
        tokenizer = LlamaModel(path: modelUrl.path)
        if tokenizer == nil {
            print("⚠️ GemmaEngine: tokenizer model failed to load — using estimate fallback.")
        }
        return tokenizer
    }

    func streamChat(
        _ messages: [LlamaChatMessage],
        temperature: Float = 0.7,
        seed: UInt32 = 42
    ) async throws -> AsyncThrowingStream<String, Error> {
        loadModelIfNeeded()

        guard isLoaded, let llama else {
            throw NSError(
                domain: "GemmaEngine",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model not loaded."]
            )
        }

        return try await llama.streamCompletion(
            of: messages,
            samplingConfig: .init(
                temperature: temperature,
                seed: seed
            )
        )
    }

    /// One-shot completion. Consumes the stream until EOS or `maxChars` is reached, whichever comes first.
    /// Used for short side-channel generations (e.g. chat title generation) that must not appear
    /// in the conversation transcript or persistent context.
    func generateOnce(
        _ messages: [LlamaChatMessage],
        temperature: Float = 0.4,
        seed: UInt32 = 7,
        maxChars: Int? = 200
    ) async throws -> String {
        let stream = try await streamChat(messages, temperature: temperature, seed: seed)
        var result = ""
        for try await token in stream {
            try Task.checkCancellation()
            result += token
            if let maxChars, result.count >= maxChars { break }
        }
        return result
    }

    private func startStagedProgress() {
        stopStagedProgress()

        progressTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled && !self.isLoaded {
                try? await Task.sleep(nanoseconds: 120_000_000)

                if self.loadProgress < 0.20 {
                    self.loadProgress = min(0.20, self.loadProgress + 0.02)
                } else if self.loadProgress < 0.80 {
                    self.loadProgress = min(0.80, self.loadProgress + 0.01)
                } else if self.loadProgress < 0.95 {
                    self.loadProgress = min(0.95, self.loadProgress + 0.003)
                } else {
                    self.loadProgress = 0.95
                }
            }
        }
    }

    private func stopStagedProgress() {
        progressTask?.cancel()
        progressTask = nil
    }
}
