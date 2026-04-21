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

    private let modelResourceName: String = "gemma-2-2b-it-Q4_K_M"
    private let modelExtension: String = "gguf"

    private let batchSize: UInt32 = 512
    private let maxTokenCount: UInt32 = 2048
    private let useGPU: Bool = true

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

    func resetModel() {
        stopStagedProgress()
        llama = nil
        isLoaded = false
        isLoading = false
        loadProgress = 0.0
        loadStatus = "Idle"
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
