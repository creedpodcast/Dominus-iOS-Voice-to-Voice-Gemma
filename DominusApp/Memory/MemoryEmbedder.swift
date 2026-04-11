import Foundation
@preconcurrency import NaturalLanguage
import Accelerate

/// Converts text into 512-dimensional float vectors using Apple's built-in
/// sentence embedding model. No external model download required.
struct MemoryEmbedder: @unchecked Sendable {

    static let shared = MemoryEmbedder()

    private let embedding: NLEmbedding?

    init() {
        self.embedding = NLEmbedding.sentenceEmbedding(for: .english)
        if embedding == nil {
            print("⚠️ MemoryEmbedder: NLEmbedding unavailable on this device.")
        }
    }

    /// Returns a 512-dim Float vector, or nil if embedding is unavailable.
    func embed(_ text: String) -> [Float]? {
        guard let embedding else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let vector = embedding.vector(for: text) else { return nil }
        return vector.map { Float($0) }
    }

    /// Hardware-accelerated cosine similarity via vDSP.
    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var magA: Float = 0
        var magB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &magA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &magB, vDSP_Length(b.count))
        let denom = sqrt(magA) * sqrt(magB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    func vectorToData(_ vector: [Float]) -> Data {
        vector.withUnsafeBytes { Data($0) }
    }

    func dataToVector(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { ptr in
            Array(ptr.bindMemory(to: Float.self).prefix(count))
        }
    }
}
