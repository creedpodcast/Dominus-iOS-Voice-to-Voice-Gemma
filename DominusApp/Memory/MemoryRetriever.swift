import Foundation

/// High-level interface for storing and retrieving conversation memory.
/// - `remember()` — embeds and stores a completed user/assistant exchange (background, fire-and-forget).
/// - `retrieve()` — returns a formatted context block of the top-K most semantically similar memories.
@MainActor
final class MemoryRetriever {

    static let shared = MemoryRetriever()

    private let store    = MemoryStore.shared
    private let embedder = MemoryEmbedder.shared

    // MARK: - Store a completed exchange

    /// Call this after the assistant finishes responding.
    /// Embedding work runs off the main thread so it never blocks the UI.
    func remember(conversationID: UUID, userText: String, assistantText: String) {
        let combined = "User: \(userText)\nAssistant: \(assistantText)"

        // Capture values before leaving actor context
        let convID = conversationID
        Task.detached(priority: .utility) { [combined, convID] in
            // NLEmbedding is documented thread-safe; fine to call off main actor
            let vec = MemoryEmbedder.shared.embed(combined)

            await MainActor.run {
                MemoryStore.shared.insert(conversationID: convID,
                                         content: combined,
                                         embedding: vec)
                MemoryStore.shared.pruneIfNeeded(conversationID: convID)
            }
        }
    }

    // MARK: - Retrieve relevant memories

    /// Returns a formatted string to inject before the system prompt.
    /// Returns `""` if no memories exist or NLEmbedding is unavailable.
    func retrieve(query: String, topK: Int = 5) -> String {
        guard let queryVec = embedder.embed(query) else { return "" }

        let all = store.fetchAll()
        guard !all.isEmpty else { return "" }

        // Score each memory against the current query
        typealias ScoredMemory = (score: Float, content: String)
        var scored: [ScoredMemory] = []
        for row in all {
            guard let vec = row.embedding else { continue }
            let score = embedder.cosineSimilarity(queryVec, vec)
            // Discard very low-relevance matches to keep the prompt clean
            guard score > 0.30 else { continue }
            scored.append((score: score, content: row.content))
        }
        scored.sort { $0.score > $1.score }
        let top = Array(scored.prefix(topK))

        guard !top.isEmpty else { return "" }

        let body = top.map { "• \($0.content)" }.joined(separator: "\n\n")
        return "Relevant past context:\n\(body)"
    }
}
