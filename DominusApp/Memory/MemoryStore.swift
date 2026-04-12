import Foundation
import SwiftData

/// SwiftData model for a single stored memory (one user+assistant exchange).
@Model
final class MemoryRecord {
    var conversationID: String
    var content: String
    var embeddingData: Data      // [Float] packed as raw bytes
    var createdAt: Date

    init(conversationID: String, content: String, embeddingData: Data, createdAt: Date = Date()) {
        self.conversationID = conversationID
        self.content        = content
        self.embeddingData  = embeddingData
        self.createdAt      = createdAt
    }
}

/// SwiftData-backed store for conversation memory.
/// Everything is saved in a local SQLite file that Apple manages automatically.
@MainActor
final class MemoryStore {

    static let shared = MemoryStore()

    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init() {
        do {
            container = try ModelContainer(for: MemoryRecord.self)
        } catch {
            fatalError("MemoryStore: failed to create SwiftData container — \(error)")
        }
    }

    // MARK: - Insert

    func insert(conversationID: UUID, content: String, embedding: [Float]?) {
        let data = embedding.map { MemoryEmbedder.shared.vectorToData($0) } ?? Data()
        let record = MemoryRecord(
            conversationID: conversationID.uuidString,
            content: content,
            embeddingData: data
        )
        context.insert(record)
        try? context.save()
    }

    // MARK: - Fetch all

    func fetchAll() -> [MemoryRecord] {
        let descriptor = FetchDescriptor<MemoryRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Prune old entries

    /// Keep only the most recent `limit` records per conversation.
    func pruneIfNeeded(conversationID: UUID, keepLatest limit: Int = 200) {
        let idStr = conversationID.uuidString
        var descriptor = FetchDescriptor<MemoryRecord>(
            predicate: #Predicate { $0.conversationID == idStr },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 9999  // fetch all to count, then delete excess

        guard let records = try? context.fetch(descriptor),
              records.count > limit else { return }

        // Delete the oldest ones beyond the limit
        for record in records.dropFirst(limit) {
            context.delete(record)
        }
        try? context.save()
    }
}
