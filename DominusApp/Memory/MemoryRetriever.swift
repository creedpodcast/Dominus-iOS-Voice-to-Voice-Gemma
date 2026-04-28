import Foundation

/// High-level interface for storing and retrieving conversation memory.
/// - `remember()` — stores a completed user/assistant exchange (fire-and-forget).
/// - `retrieve()` — returns the top-K most relevant memories as a formatted string.
///
/// Two retrieval modes:
///   • Semantic  — NLEmbedding cosine similarity (best, when Apple's model is available)
///   • Keyword   — word-overlap scoring (fallback, always works)
@MainActor
final class MemoryRetriever {

    static let shared = MemoryRetriever()

    private let store    = MemoryStore.shared
    private let embedder = MemoryEmbedder.shared

    // MARK: - Store a completed exchange

    func remember(conversationID: UUID, userText: String, assistantText: String) {
        let combined = "User: \(userText)\nAssistant: \(assistantText)"
        let convID   = conversationID

        Task.detached(priority: .utility) {
            // Try to get a semantic embedding; nil is fine — keyword fallback covers it
            let vec = MemoryEmbedder.shared.embed(combined)
            if vec == nil {
                print("⚠️ MemoryRetriever: NLEmbedding unavailable — saving without vector (keyword fallback will be used)")
            }
            await MainActor.run {
                MemoryStore.shared.insert(conversationID: convID,
                                         content: combined,
                                         embedding: vec)
                MemoryStore.shared.pruneIfNeeded(conversationID: convID)
                let total = MemoryStore.shared.fetchAll().count
                print("🧠 Memory saved (\(convID.uuidString.prefix(8))). Total records: \(total)")
            }
        }
    }

    // MARK: - Retrieve relevant memories

    /// Returns the top-K most relevant memories for `query` *within a single conversation*.
    /// Cross-conversation retrieval was removed because semantic matches between
    /// unrelated chats caused old-chat content to bleed into new chats.
    func retrieve(query: String, conversationID: UUID, topK: Int = 5) -> String {
        let all = store.fetch(conversationID: conversationID)
        guard !all.isEmpty else {
            print("🔍 RAG: no memories for this conversation yet")
            return ""
        }

        // Decide retrieval strategy based on whether NLEmbedding is available
        let queryVec = embedder.embed(query)

        typealias ScoredMemory = (score: Float, content: String)
        var scored: [ScoredMemory] = []

        if let qv = queryVec {
            // ── Semantic path ──────────────────────────────────────────
            print("🔍 RAG: using semantic search | candidates: \(all.count)")
            for record in all {
                guard !record.embeddingData.isEmpty else { continue }
                let vec   = embedder.dataToVector(record.embeddingData)
                let score = embedder.cosineSimilarity(qv, vec)
                guard score > 0.15 else { continue }
                scored.append((score: score, content: record.content))
            }
        } else {
            // ── Keyword fallback ───────────────────────────────────────
            print("🔍 RAG: using keyword fallback | candidates: \(all.count)")
            let queryWords = keywords(from: query)
            for record in all {
                let score = keywordScore(queryWords: queryWords, text: record.content)
                guard score > 0 else { continue }
                scored.append((score: score, content: record.content))
            }
        }

        scored.sort { $0.score > $1.score }
        let top = Array(scored.prefix(topK))

        print("🔍 RAG matched: \(top.count)")
        for m in top {
            print("   score \(String(format: "%.2f", m.score)): \(m.content.prefix(80))…")
        }

        guard !top.isEmpty else { return "" }

        let body = top.map { "• \($0.content)" }.joined(separator: "\n\n")
        return "Relevant past context (user told you these things previously):\n\(body)"
    }

    // MARK: - Keyword scoring helpers

    /// Meaningful words from a string (lowercased, stop-words removed, length > 2)
    private func keywords(from text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the","a","an","is","it","in","on","at","to","of","and","or","but",
            "was","are","be","been","my","i","you","me","he","she","we","they",
            "did","do","does","did","what","who","how","when","where","why",
            "that","this","these","those","so","if","as","up","for","with","said"
        ]
        return Set(
            text.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count > 2 && !stopWords.contains($0) }
        )
    }

    /// Word-overlap Jaccard-style score between the query and a memory record
    private func keywordScore(queryWords: Set<String>, text: String) -> Float {
        guard !queryWords.isEmpty else { return 0 }
        let recordWords = keywords(from: text)
        guard !recordWords.isEmpty else { return 0 }
        let overlap = queryWords.intersection(recordWords).count
        return Float(overlap) / Float(queryWords.count)
    }
}
