import Foundation
import SwiftData

enum MemoryKind: String, Codable, CaseIterable, Sendable {
    case conversationExchange
    case conversationSummary
    case userFact
    case preference
    case goal
    case taskReference
    case wikiEntry
    case appInstruction
    case memoryCandidate

    var promptLabel: String {
        switch self {
        case .conversationExchange: return "Past exchange"
        case .conversationSummary:  return "Conversation summary"
        case .userFact:             return "User fact"
        case .preference:           return "Preference"
        case .goal:                 return "Goal"
        case .taskReference:        return "Task reference"
        case .wikiEntry:            return "Reference block"
        case .appInstruction:       return "App guide"
        case .memoryCandidate:      return "Suggested memory"
        }
    }
}

enum MemoryScope: String, Codable, CaseIterable, Sendable {
    case conversation
    case longTerm
    case wiki
}

enum MemoryHubCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case profile
    case writing
    case business
    case projects
    case goals
    case health
    case finances
    case preferences
    case tasks
    case appInstructions
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile:         return "Profile"
        case .writing:         return "Writing"
        case .business:        return "Business"
        case .projects:        return "Projects"
        case .goals:           return "Goals"
        case .health:          return "Health & Fitness"
        case .finances:        return "Finances"
        case .preferences:     return "Preferences"
        case .tasks:           return "Daily Goals & Tasks"
        case .appInstructions: return "App Instructions"
        case .general:         return "General"
        }
    }
}

struct MemoryCategoryInfo: Identifiable, Hashable {
    let id: String
    var title: String
    var icon: String
    var defaultKind: MemoryKind
    var isCustom: Bool
}

/// SwiftData model for a single stored memory chunk.
@Model
final class MemoryRecord {
    /// Empty string means the memory is global rather than tied to one chat.
    var conversationID: String
    var kindRaw: String = MemoryKind.conversationExchange.rawValue
    var scopeRaw: String = MemoryScope.conversation.rawValue
    var title: String?
    var sourceID: String?
    var categoryRaw: String?
    var content: String
    var embeddingData: Data      // [Float] packed as raw bytes
    var createdAt: Date
    var updatedAt: Date = Date()

    init(
        conversationID: String,
        kind: MemoryKind,
        scope: MemoryScope,
        title: String? = nil,
        sourceID: String? = nil,
        categoryRaw: String? = nil,
        content: String,
        embeddingData: Data,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.conversationID = conversationID
        self.kindRaw        = kind.rawValue
        self.scopeRaw       = scope.rawValue
        self.title          = title
        self.sourceID       = sourceID
        self.categoryRaw    = categoryRaw
        self.content        = content
        self.embeddingData  = embeddingData
        self.createdAt      = createdAt
        self.updatedAt      = updatedAt
    }

    var kind: MemoryKind {
        MemoryKind(rawValue: kindRaw) ?? .conversationExchange
    }

    var scope: MemoryScope {
        MemoryScope(rawValue: scopeRaw) ?? .conversation
    }
}

/// Centralized category summary over long-term memory, like a local memory map.
@Model
final class MemoryHubRecord {
    var categoryRaw: String
    var title: String
    var summary: String
    var embeddingData: Data
    var sourceCount: Int
    var updatedAt: Date = Date()

    init(
        category: MemoryHubCategory,
        categoryRaw: String? = nil,
        title: String,
        summary: String,
        embeddingData: Data = Data(),
        sourceCount: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.categoryRaw = categoryRaw ?? category.rawValue
        self.title = title
        self.summary = summary
        self.embeddingData = embeddingData
        self.sourceCount = sourceCount
        self.updatedAt = updatedAt
    }

    var category: MemoryHubCategory {
        MemoryHubCategory(rawValue: categoryRaw) ?? .general
    }
}

/// SwiftData-backed store for conversation memory.
/// Everything is saved in a local SQLite file that Apple manages automatically.
@MainActor
final class MemoryStore {

    static let shared = MemoryStore()
    static let uncategorizedCategoryKey = MemoryHubCategory.general.rawValue

    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private let customCategoriesKey = "dominus_memory_custom_categories"

    init() {
        do {
            let schema = Schema([MemoryRecord.self, MemoryHubRecord.self])
            let supportURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let storeURL = supportURL.appendingPathComponent("DominusMemory.store")
            let configuration = ModelConfiguration(
                "DominusMemory",
                schema: schema,
                url: storeURL
            )
            container = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
        } catch {
            fatalError("MemoryStore: failed to create SwiftData container — \(error)")
        }
    }

    // MARK: - Insert

    @discardableResult
    func insert(
        conversationID: UUID?,
        kind: MemoryKind,
        scope: MemoryScope,
        title: String? = nil,
        sourceID: String? = nil,
        categoryKey: String? = nil,
        content: String,
        embedding: [Float]?
    ) -> MemoryRecord {
        let data = embedding.map { MemoryEmbedder.shared.vectorToData($0) } ?? Data()
        let record = MemoryRecord(
            conversationID: conversationID?.uuidString ?? "",
            kind: kind,
            scope: scope,
            title: title,
            sourceID: sourceID,
            categoryRaw: categoryKey,
            content: content,
            embeddingData: data,
            updatedAt: Date()
        )
        context.insert(record)
        try? context.save()
        if scope != .conversation {
            rebuildHub()
        }
        return record
    }

    // MARK: - Fetch all

    func fetchAll() -> [MemoryRecord] {
        let descriptor = FetchDescriptor<MemoryRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Fetch only the memories that belong to a single conversation.
    /// Used by RAG retrieval so a new chat never pulls context from an unrelated chat.
    func fetch(conversationID: UUID) -> [MemoryRecord] {
        let idStr = conversationID.uuidString
        let descriptor = FetchDescriptor<MemoryRecord>(
            predicate: #Predicate { $0.conversationID == idStr },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetch(scope: MemoryScope) -> [MemoryRecord] {
        let raw = scope.rawValue
        let descriptor = FetchDescriptor<MemoryRecord>(
            predicate: #Predicate { $0.scopeRaw == raw },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchHubRecords() -> [MemoryHubRecord] {
        let descriptor = FetchDescriptor<MemoryHubRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchHubSourceRecords(category: MemoryHubCategory) -> [MemoryRecord] {
        fetchHubSourceRecords(categoryKey: category.rawValue)
    }

    func fetchHubSourceRecords(categoryKey: String) -> [MemoryRecord] {
        fetch(scope: .longTerm)
            .filter { $0.kind != .memoryCandidate && resolvedCategoryKey(for: $0) == categoryKey }
    }

    func rebuildHub() {
        let sourceRecords = fetch(scope: .longTerm)
            .filter { $0.kind != .memoryCandidate }
        let grouped = Dictionary(grouping: sourceRecords) { resolvedCategoryKey(for: $0) }
        let activeCategoryKeys = Set(grouped.keys)
        let allCategoryKeys = Set(memoryCategories().map(\.id)).union(activeCategoryKeys)
        var hubEmbeddingJobs: [(categoryKey: String, summary: String)] = []

        for categoryKey in allCategoryKeys.sorted(by: categorySort) {
            let records = grouped[categoryKey] ?? []
            let existing = fetchHubRecords().first { $0.categoryRaw == categoryKey }

            guard !records.isEmpty else {
                if let existing {
                    context.delete(existing)
                }
                continue
            }

            let summary = hubSummary(for: records)
            let category = memoryCategoryInfo(for: categoryKey)
            if let existing {
                existing.title = category.title
                existing.summary = summary
                existing.sourceCount = records.count
                existing.updatedAt = Date()
            } else {
                context.insert(MemoryHubRecord(
                    category: MemoryHubCategory(rawValue: categoryKey) ?? .general,
                    categoryRaw: categoryKey,
                    title: category.title,
                    summary: summary,
                    embeddingData: Data(),
                    sourceCount: records.count,
                    updatedAt: Date()
                ))
            }
            hubEmbeddingJobs.append((categoryKey: categoryKey, summary: summary))
        }

        try? context.save()

        for job in hubEmbeddingJobs {
            scheduleHubEmbedding(categoryKey: job.categoryKey, summary: job.summary)
        }
    }

    func memoryCategories() -> [MemoryCategoryInfo] {
        let system = MemoryHubCategory.allCases.map { categoryInfo(for: $0) }
        return system + customCategoryKeys().map {
            MemoryCategoryInfo(
                id: $0,
                title: categoryTitle(from: $0),
                icon: "folder.badge.person.crop",
                defaultKind: .userFact,
                isCustom: true
            )
        }
    }

    func memoryCategoryInfo(for key: String) -> MemoryCategoryInfo {
        if let system = MemoryHubCategory(rawValue: key) {
            return categoryInfo(for: system)
        }
        return MemoryCategoryInfo(
            id: key,
            title: categoryTitle(from: key),
            icon: "folder.badge.person.crop",
            defaultKind: .userFact,
            isCustom: true
        )
    }

    func memoryCategoryInfo(for record: MemoryRecord) -> MemoryCategoryInfo {
        memoryCategoryInfo(for: resolvedCategoryKey(for: record))
    }

    @discardableResult
    func addCustomCategory(title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var keys = customCategoryKeys()
        let key = uniqueCustomCategoryKey(for: trimmed, existing: Set(keys).union(MemoryHubCategory.allCases.map(\.rawValue)))
        keys.append(key)
        saveCustomCategoryKeys(keys)
        rebuildHub()
        return key
    }

    func updateEmbedding(
        scope: MemoryScope,
        sourceID: String?,
        content: String,
        embedding: [Float]?
    ) {
        guard let embedding else { return }
        let data = MemoryEmbedder.shared.vectorToData(embedding)
        let normalizedContent = normalized(content)

        let matches = fetch(scope: scope).filter { record in
            if let sourceID {
                return record.sourceID == sourceID
            }
            return normalized(record.content) == normalizedContent
        }

        guard !matches.isEmpty else { return }
        matches.forEach { record in
            record.embeddingData = data
            record.updatedAt = Date()
        }
        try? context.save()
    }

    func update(
        _ record: MemoryRecord,
        kind: MemoryKind,
        title: String?,
        content: String,
        categoryKey: String? = nil
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        record.kindRaw = kind.rawValue
        record.title = cleanTitle.isEmpty ? nil : cleanTitle
        record.categoryRaw = categoryKey
        record.content = trimmed
        record.updatedAt = Date()
        record.embeddingData = Data()
        try? context.save()

        if record.scope != .conversation {
            scheduleRecordEmbedding(record: record, content: trimmed)
            rebuildHub()
        }
    }

    private func updateHubEmbedding(
        categoryKey: String,
        summary: String,
        embedding: [Float]?
    ) {
        guard let embedding else { return }
        let normalizedSummary = normalized(summary)
        guard let record = fetchHubRecords().first(where: {
            $0.categoryRaw == categoryKey && normalized($0.summary) == normalizedSummary
        }) else { return }

        record.embeddingData = MemoryEmbedder.shared.vectorToData(embedding)
        record.updatedAt = Date()
        try? context.save()
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

    func delete(conversationID: UUID) {
        let idStr = conversationID.uuidString
        let descriptor = FetchDescriptor<MemoryRecord>(
            predicate: #Predicate { $0.conversationID == idStr }
        )
        guard let records = try? context.fetch(descriptor) else { return }
        records.forEach { context.delete($0) }
        try? context.save()
    }

    func delete(_ record: MemoryRecord) {
        context.delete(record)
        try? context.save()
        rebuildHub()
    }

    func deleteMatching(content: String) {
        let tokens = significantTokens(from: content)
        guard !tokens.isEmpty else { return }

        let records = fetchAll().filter { record in
            let recordTokens = significantTokens(from: record.content)
            guard !recordTokens.isEmpty else { return false }
            let overlap = tokens.intersection(recordTokens).count
            let threshold = min(3, max(1, tokens.count))
            return overlap >= threshold || recordTokens.isSubset(of: tokens) || tokens.isSubset(of: recordTokens)
        }

        records.forEach { context.delete($0) }
        try? context.save()
        rebuildHub()
    }

    func delete(scope: MemoryScope, sourceID: String) {
        let records = fetch(scope: scope).filter { $0.sourceID == sourceID }
        records.forEach { context.delete($0) }
        try? context.save()
        rebuildHub()
    }

    private func significantTokens(from text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the","a","an","is","it","in","on","at","to","of","and","or","but",
            "was","are","be","been","my","i","you","me","he","she","we","they",
            "did","do","does","what","who","how","when","where","why","that",
            "this","these","those","so","if","as","up","for","with","said",
            "user","fact","preference","goal","memory","possible","long","term"
        ]
        return Set(
            text.lowercased()
                .replacingOccurrences(of: "•", with: " ")
                .components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count > 2 && !stopWords.contains($0) }
        )
    }

    private func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "•", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleHubEmbedding(categoryKey: String, summary: String) {
        Task.detached(priority: .utility) {
            let embedding = MemoryEmbedder.shared.embed(summary)
            await MainActor.run {
                MemoryStore.shared.updateHubEmbedding(
                    categoryKey: categoryKey,
                    summary: summary,
                    embedding: embedding
                )
            }
        }
    }

    private func scheduleRecordEmbedding(record: MemoryRecord, content: String) {
        let scope = record.scope
        let sourceID = record.sourceID
        Task.detached(priority: .utility) {
            let embedding = MemoryEmbedder.shared.embed(content)
            await MainActor.run {
                MemoryStore.shared.updateEmbedding(
                    scope: scope,
                    sourceID: sourceID,
                    content: content,
                    embedding: embedding
                )
            }
        }
    }

    private func hubSummary(for records: [MemoryRecord]) -> String {
        records.prefix(12).map { record in
            let text = record.content
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("•") {
                return text
            }
            return "• \(text)"
        }
        .joined(separator: "\n")
    }

    private func resolvedCategoryKey(for record: MemoryRecord) -> String {
        if let categoryRaw = record.categoryRaw,
           memoryCategories().contains(where: { $0.id == categoryRaw }) {
            return categoryRaw
        }
        return inferredCategory(for: record).rawValue
    }

    private func inferredCategory(for record: MemoryRecord) -> MemoryHubCategory {
        if record.kind == .preference { return .preferences }
        if record.kind == .goal { return .goals }
        if record.kind == .taskReference { return .tasks }
        if record.kind == .appInstruction { return .appInstructions }

        let text = "\(record.title ?? "") \(record.content)".lowercased()
        if text.contains("book") || text.contains("writing") || text.contains("chapter") ||
            text.contains("novel") || text.contains("manuscript") {
            return .writing
        }
        if text.contains("business") || text.contains("company") || text.contains("store") ||
            text.contains("startup") || text.contains("brand") {
            return .business
        }
        if text.contains("project") || text.contains("app") || text.contains("dominus") ||
            text.contains("ai assistant") {
            return .projects
        }
        if text.contains("health") || text.contains("fitness") || text.contains("workout") ||
            text.contains("lifting") || text.contains("diet") {
            return .health
        }
        if text.contains("finance") || text.contains("money") || text.contains("budget") ||
            text.contains("income") || text.contains("invest") {
            return .finances
        }
        if text.contains("favorite") || text.contains("prefer") || text.contains("like") ||
            text.contains("love") || text.contains("dislike") {
            return .preferences
        }
        if text.contains("profile") || text.contains("name") || text.contains("called") || text.contains("location") ||
            text.contains("occupation") || text.contains("role") {
            return .profile
        }
        return .general
    }

    private func categoryInfo(for category: MemoryHubCategory) -> MemoryCategoryInfo {
        MemoryCategoryInfo(
            id: category.rawValue,
            title: category.title,
            icon: icon(for: category),
            defaultKind: defaultKind(for: category),
            isCustom: false
        )
    }

    private func icon(for category: MemoryHubCategory) -> String {
        switch category {
        case .profile:         return "person.text.rectangle"
        case .writing:         return "pencil.and.scribble"
        case .business:        return "briefcase"
        case .projects:        return "folder"
        case .goals:           return "target"
        case .health:          return "heart"
        case .finances:        return "dollarsign.circle"
        case .preferences:     return "star"
        case .tasks:           return "checklist"
        case .appInstructions: return "gearshape"
        case .general:         return "square.grid.2x2"
        }
    }

    private func defaultKind(for category: MemoryHubCategory) -> MemoryKind {
        switch category {
        case .preferences:
            return .preference
        case .goals:
            return .goal
        case .tasks:
            return .taskReference
        case .appInstructions:
            return .appInstruction
        default:
            return .userFact
        }
    }

    private func customCategoryKeys() -> [String] {
        UserDefaults.standard.stringArray(forKey: customCategoriesKey) ?? []
    }

    private func saveCustomCategoryKeys(_ keys: [String]) {
        var seen = Set<String>()
        let unique = keys.filter { seen.insert($0).inserted }
        UserDefaults.standard.set(unique, forKey: customCategoriesKey)
    }

    private func uniqueCustomCategoryKey(for title: String, existing: Set<String>) -> String {
        let base = "custom:" + title.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let cleanBase = base == "custom:" ? "custom:category" : base
        var candidate = cleanBase
        var index = 2
        while existing.contains(candidate) {
            candidate = "\(cleanBase)-\(index)"
            index += 1
        }
        return candidate
    }

    private func categoryTitle(from key: String) -> String {
        let raw = key.hasPrefix("custom:") ? String(key.dropFirst("custom:".count)) : key
        return raw
            .split(separator: "-")
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }

    private func categorySort(_ lhs: String, _ rhs: String) -> Bool {
        let leftSystemIndex = MemoryHubCategory.allCases.firstIndex { $0.rawValue == lhs }
        let rightSystemIndex = MemoryHubCategory.allCases.firstIndex { $0.rawValue == rhs }
        switch (leftSystemIndex, rightSystemIndex) {
        case let (left?, right?):
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return categoryTitle(from: lhs) < categoryTitle(from: rhs)
        }
    }
}
