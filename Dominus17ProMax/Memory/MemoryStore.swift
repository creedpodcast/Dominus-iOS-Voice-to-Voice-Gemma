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
    /// Reserved for future file chunk indexing: file -> chunks -> embeddings -> retrieved candidates.
    case file
}

enum MemoryHubCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case identity
    case profile
    case project
    case writing
    case business
    case projects
    case goals
    case belief
    case technical
    case creative
    case file
    case relationship
    case location
    case securityWork
    case podcast
    case book
    case music
    case appDevelopment
    case health
    case finances
    case preferences
    case tasks
    case appInstructions
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .identity:        return "Identity"
        case .profile:         return "Profile"
        case .project:         return "Project"
        case .writing:         return "Writing"
        case .business:        return "Business"
        case .projects:        return "Projects"
        case .goals:           return "Goals"
        case .belief:          return "Beliefs"
        case .technical:       return "Technical"
        case .creative:        return "Creative"
        case .file:            return "Files"
        case .relationship:    return "Relationships"
        case .location:        return "Location"
        case .securityWork:    return "Security Work"
        case .podcast:         return "Podcast"
        case .book:            return "Books"
        case .music:           return "Music"
        case .appDevelopment:  return "App Development"
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

struct MemoryRecordMetadata {
    var topics: [String]
    var entities: [String]
    var meaningSignals: [String]
    var emotionalTone: String?
    var importanceScore: Double
    var semanticContext: String
}

enum MemoryEmbeddingAspect: String, CaseIterable, Codable, Sendable {
    case literal
    case topical
    case emotional
    case preference
    case identity

    var promptLabel: String {
        switch self {
        case .literal:    return "literal"
        case .topical:    return "topic"
        case .emotional:  return "emotional"
        case .preference: return "preference"
        case .identity:   return "identity"
        }
    }
}

enum MemoryMetadataBuilder {
    static func build(
        content: String,
        kind: MemoryKind,
        categoryKey: String?,
        title: String?
    ) -> MemoryRecordMetadata {
        let text = normalized(content)
        let lower = text.lowercased()
        let category = categoryKey ?? MemoryStore.uncategorizedCategoryKey
        let topics = inferredTopics(from: lower, kind: kind, categoryKey: category)
        let entities = inferredEntities(from: text)
        let signals = inferredMeaningSignals(from: lower, kind: kind)
        let tone = inferredTone(from: lower)
        let importance = inferredImportance(
            from: lower,
            kind: kind,
            categoryKey: category,
            topicCount: topics.count,
            entityCount: entities.count
        )

        let contextParts = [
            title.map { "Title: \($0)" },
            "Kind: \(kind.promptLabel)",
            "Category: \(category)",
            topics.isEmpty ? nil : "Topics: \(topics.joined(separator: ", "))",
            entities.isEmpty ? nil : "People or entities: \(entities.joined(separator: ", "))",
            signals.isEmpty ? nil : "Meaning signals: \(signals.joined(separator: ", "))",
            tone.map { "Tone: \($0)" },
            "Memory: \(text)"
        ].compactMap { $0 }

        return MemoryRecordMetadata(
            topics: topics,
            entities: entities,
            meaningSignals: signals,
            emotionalTone: tone,
            importanceScore: importance,
            semanticContext: contextParts.joined(separator: "\n")
        )
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inferredTopics(from lower: String, kind: MemoryKind, categoryKey: String) -> [String] {
        var topics: [String] = []
        func add(_ topic: String) {
            guard !topics.contains(topic) else { return }
            topics.append(topic)
        }

        add(categoryKey.replacingOccurrences(of: "custom:", with: ""))
        if kind == .preference { add("preference") }
        if kind == .goal { add("goal") }
        if kind == .taskReference { add("task") }
        if kind == .appInstruction { add("instruction") }

        let topicRules: [(String, [String])] = [
            ("identity", ["name", "called", "identity", "profile", "occupation", "role"]),
            ("location", ["location", "city", "state", "lives", "home"]),
            ("relationship", ["wife", "family", "friend", "team", "relationship"]),
            ("health", ["gym", "workout", "fitness", "diet", "health", "sleep"]),
            ("writing", ["book", "writing", "chapter", "story", "novel", "manuscript"]),
            ("project", ["project", "building", "working on", "app", "startup"]),
            ("dominus", ["dominus", "assistant", "voice", "memory", "rag", "swiftui", "xcode", "ios"]),
            ("design", ["design", "ui", "ux", "interface", "feel", "style"]),
            ("faith", ["god", "faith", "bible", "scripture", "prayer", "belief"]),
            ("business", ["business", "brand", "company", "store", "customer"]),
            ("finance", ["money", "budget", "income", "finance", "invest"]),
            ("security", ["security", "sop", "risk", "threat", "investigation"]),
            ("music", ["music", "song", "album", "artist"]),
            ("podcast", ["podcast", "episode", "show"]),
            ("learning", ["course", "class", "training", "study", "learn"])
        ]

        for (topic, needles) in topicRules where needles.contains(where: { lower.contains($0) }) {
            add(topic)
        }

        return Array(topics.prefix(8))
    }

    private static func inferredEntities(from text: String) -> [String] {
        let stopWords: Set<String> = [
            "Creed", "User", "Dominus", "Memory", "The", "This", "That", "And", "But",
            "For", "With", "From", "When", "Where", "What", "Why", "How"
        ]
        guard let regex = try? NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9]*(?:\s+[A-Z][A-Za-z0-9]*){0,3}\b"#) else {
            return []
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var seen = Set<String>()
        let entities = matches.compactMap { match -> String? in
            let value = nsText.substring(with: match.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count > 2,
                  !stopWords.contains(value),
                  !seen.contains(value)
            else { return nil }
            seen.insert(value)
            return value
        }
        return Array(entities.prefix(8))
    }

    private static func inferredMeaningSignals(from lower: String, kind: MemoryKind) -> [String] {
        var signals: [String] = []
        func add(_ signal: String) {
            guard !signals.contains(signal) else { return }
            signals.append(signal)
        }

        switch kind {
        case .preference:
            add("personal taste")
        case .goal:
            add("future intent")
        case .taskReference:
            add("active work")
        case .appInstruction:
            add("assistant behavior")
        case .userFact:
            add("stable user fact")
        default:
            break
        }

        if lower.contains("prefer") || lower.contains("like") || lower.contains("love") || lower.contains("favorite") {
            add("preference")
        }
        if lower.contains("hate") || lower.contains("dislike") || lower.contains("do not like") {
            add("negative preference")
        }
        if lower.contains("want") || lower.contains("need") || lower.contains("plan") || lower.contains("considering") {
            add("goal or intention")
        }
        if lower.contains("worried") || lower.contains("concern") || lower.contains("afraid") || lower.contains("anxious") {
            add("concern")
        }
        if lower.contains("remember") || lower.contains("always") || lower.contains("never") {
            add("high recall value")
        }
        if lower.contains("feel") || lower.contains("vibe") || lower.contains("tone") {
            add("experience preference")
        }
        return signals
    }

    private static func inferredTone(from lower: String) -> String? {
        if lower.contains("love") || lower.contains("excited") || lower.contains("favorite") || lower.contains("enjoy") {
            return "positive"
        }
        if lower.contains("hate") || lower.contains("frustrated") || lower.contains("annoy") || lower.contains("dislike") {
            return "negative"
        }
        if lower.contains("worried") || lower.contains("concern") || lower.contains("afraid") || lower.contains("anxious") {
            return "concerned"
        }
        if lower.contains("need") || lower.contains("must") || lower.contains("important") || lower.contains("always") || lower.contains("never") {
            return "urgent"
        }
        return nil
    }

    private static func inferredImportance(
        from lower: String,
        kind: MemoryKind,
        categoryKey: String,
        topicCount: Int,
        entityCount: Int
    ) -> Double {
        var score = 0.45
        if kind == .goal || kind == .taskReference || kind == .appInstruction { score += 0.18 }
        if kind == .preference { score += 0.12 }
        if categoryKey == MemoryHubCategory.appDevelopment.rawValue || categoryKey == MemoryHubCategory.identity.rawValue {
            score += 0.08
        }
        if lower.contains("always") || lower.contains("never") || lower.contains("important") || lower.contains("remember") {
            score += 0.15
        }
        if lower.contains("dominus") || lower.contains("octobrain") || lower.contains("project") || lower.contains("working on") {
            score += 0.1
        }
        score += min(0.1, Double(topicCount + entityCount) * 0.015)
        return min(1, max(0.1, score))
    }
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
    var literalEmbeddingData: Data = Data()
    var topicalEmbeddingData: Data = Data()
    var emotionalEmbeddingData: Data = Data()
    var preferenceEmbeddingData: Data = Data()
    var identityEmbeddingData: Data = Data()
    var topicsRaw: String = ""
    var entitiesRaw: String = ""
    var meaningSignalsRaw: String = ""
    var emotionalToneRaw: String?
    var importanceScore: Double = 0.45
    var recurrenceCount: Int = 1
    var semanticContext: String = ""
    /// 1-based ordinal of the user turn this record came from, for chronological
    /// ordering and positional recall. -1 means unknown (older records predating
    /// this field, or non-turn records). Default keeps SwiftData migration lightweight.
    var turnIndex: Int = -1
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
        metadata: MemoryRecordMetadata? = nil,
        turnIndex: Int = -1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        let resolvedMetadata = metadata ?? MemoryMetadataBuilder.build(
            content: content,
            kind: kind,
            categoryKey: categoryRaw,
            title: title
        )
        self.conversationID = conversationID
        self.kindRaw        = kind.rawValue
        self.scopeRaw       = scope.rawValue
        self.title          = title
        self.sourceID       = sourceID
        self.categoryRaw    = categoryRaw
        self.content        = content
        self.embeddingData  = embeddingData
        self.topicsRaw = resolvedMetadata.topics.joined(separator: "|")
        self.entitiesRaw = resolvedMetadata.entities.joined(separator: "|")
        self.meaningSignalsRaw = resolvedMetadata.meaningSignals.joined(separator: "|")
        self.emotionalToneRaw = resolvedMetadata.emotionalTone
        self.importanceScore = resolvedMetadata.importanceScore
        self.semanticContext = resolvedMetadata.semanticContext
        self.turnIndex      = turnIndex
        self.createdAt      = createdAt
        self.updatedAt      = updatedAt
    }

    var kind: MemoryKind {
        MemoryKind(rawValue: kindRaw) ?? .conversationExchange
    }

    var scope: MemoryScope {
        MemoryScope(rawValue: scopeRaw) ?? .conversation
    }

    var topics: [String] {
        splitMetadata(topicsRaw)
    }

    var entities: [String] {
        splitMetadata(entitiesRaw)
    }

    var meaningSignals: [String] {
        splitMetadata(meaningSignalsRaw)
    }

    var embeddingText: String {
        semanticContext.isEmpty ? content : semanticContext
    }

    var hasEmbeddingVariants: Bool {
        !literalEmbeddingData.isEmpty &&
        !topicalEmbeddingData.isEmpty &&
        !emotionalEmbeddingData.isEmpty &&
        !preferenceEmbeddingData.isEmpty &&
        !identityEmbeddingData.isEmpty
    }

    var embeddingVariantCount: Int {
        MemoryEmbeddingAspect.allCases.filter {
            !embeddingData(for: $0).isEmpty
        }.count
    }

    var retrievalText: String {
        [
            title,
            content,
            semanticContext,
            topics.joined(separator: " "),
            entities.joined(separator: " "),
            meaningSignals.joined(separator: " "),
            emotionalToneRaw
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    func embeddingData(for aspect: MemoryEmbeddingAspect) -> Data {
        switch aspect {
        case .literal:    return literalEmbeddingData
        case .topical:    return topicalEmbeddingData
        case .emotional:  return emotionalEmbeddingData
        case .preference: return preferenceEmbeddingData
        case .identity:   return identityEmbeddingData
        }
    }

    func embeddingText(for aspect: MemoryEmbeddingAspect) -> String {
        switch aspect {
        case .literal:
            return content
        case .topical:
            return [
                title.map { "Title: \($0)" },
                "Topics: \(topics.joined(separator: ", "))",
                "Category: \(categoryRaw ?? MemoryStore.uncategorizedCategoryKey)",
                "Memory: \(content)"
            ].compactMap { $0 }.joined(separator: "\n")
        case .emotional:
            return [
                emotionalToneRaw.map { "Emotional tone: \($0)" },
                meaningSignals.isEmpty ? nil : "Meaning signals: \(meaningSignals.joined(separator: ", "))",
                "Memory: \(content)"
            ].compactMap { $0 }.joined(separator: "\n")
        case .preference:
            return [
                "Preference, goal, concern, or constraint for Creed.",
                "Kind: \(kind.promptLabel)",
                meaningSignals.isEmpty ? nil : "Meaning signals: \(meaningSignals.joined(separator: ", "))",
                "Memory: \(content)"
            ].compactMap { $0 }.joined(separator: "\n")
        case .identity:
            return [
                "Identity, style, relationship, project, or personal-history signal for Creed.",
                entities.isEmpty ? nil : "People or entities: \(entities.joined(separator: ", "))",
                topics.isEmpty ? nil : "Topics: \(topics.joined(separator: ", "))",
                "Memory: \(content)"
            ].compactMap { $0 }.joined(separator: "\n")
        }
    }

    private func splitMetadata(_ raw: String) -> [String] {
        raw.split(separator: "|").map(String.init).filter { !$0.isEmpty }
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
    static let refinedOnceSourceMarker = "refined-once"
    static let pendingAISummarySourceMarker = "pending-ai-summary"

    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private let customCategoriesKey = "dominus_memory_custom_categories"
    private var scheduledEmbeddingBackfillKeys = Set<String>()

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
        embedding: [Float]?,
        turnIndex: Int = -1
    ) -> MemoryRecord {
        let metadata = MemoryMetadataBuilder.build(
            content: content,
            kind: kind,
            categoryKey: categoryKey,
            title: title
        )
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
            metadata: metadata,
            turnIndex: turnIndex,
            updatedAt: Date()
        )
        context.insert(record)
        try? context.save()
        if scope != .conversation {
            rebuildHub()
        }
        scheduleRecordEmbedding(record: record, content: content)
        return record
    }

    // MARK: - Fetch all

    func fetchAll() -> [MemoryRecord] {
        let descriptor = FetchDescriptor<MemoryRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return hydrateMetadataIfNeeded((try? context.fetch(descriptor)) ?? [])
    }

    /// Fetch only the memories that belong to a single conversation.
    /// Used by RAG retrieval so a new chat never pulls context from an unrelated chat.
    func fetch(conversationID: UUID) -> [MemoryRecord] {
        let idStr = conversationID.uuidString
        let descriptor = FetchDescriptor<MemoryRecord>(
            predicate: #Predicate { $0.conversationID == idStr },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return hydrateMetadataIfNeeded((try? context.fetch(descriptor)) ?? [])
    }

    func fetch(scope: MemoryScope) -> [MemoryRecord] {
        let raw = scope.rawValue
        let descriptor = FetchDescriptor<MemoryRecord>(
            predicate: #Predicate { $0.scopeRaw == raw },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return hydrateMetadataIfNeeded((try? context.fetch(descriptor)) ?? [])
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

        let matches = fetchRaw(scope: scope).filter { record in
            if let sourceID {
                return record.sourceID == sourceID && normalized(record.content) == normalizedContent
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

    func updateEmbeddingVariants(
        scope: MemoryScope,
        sourceID: String?,
        content: String,
        embeddings: [MemoryEmbeddingAspect: [Float]]
    ) {
        guard !embeddings.isEmpty else { return }
        let normalizedContent = normalized(content)

        let matches = fetchRaw(scope: scope).filter { record in
            if let sourceID {
                return record.sourceID == sourceID && normalized(record.content) == normalizedContent
            }
            return normalized(record.content) == normalizedContent
        }

        guard !matches.isEmpty else { return }
        matches.forEach { record in
            for (aspect, vector) in embeddings {
                let data = MemoryEmbedder.shared.vectorToData(vector)
                switch aspect {
                case .literal:
                    record.literalEmbeddingData = data
                case .topical:
                    record.topicalEmbeddingData = data
                case .emotional:
                    record.emotionalEmbeddingData = data
                case .preference:
                    record.preferenceEmbeddingData = data
                case .identity:
                    record.identityEmbeddingData = data
                }
            }
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
        let metadata = MemoryMetadataBuilder.build(
            content: trimmed,
            kind: kind,
            categoryKey: categoryKey,
            title: cleanTitle.isEmpty ? nil : cleanTitle
        )
        record.kindRaw = kind.rawValue
        record.title = cleanTitle.isEmpty ? nil : cleanTitle
        record.categoryRaw = categoryKey
        record.content = trimmed
        apply(metadata, to: record)
        record.updatedAt = Date()
        record.embeddingData = Data()
        clearEmbeddingVariants(for: record)
        try? context.save()

        if record.scope != .conversation {
            scheduleRecordEmbedding(record: record, content: trimmed)
            rebuildHub()
        }
    }

    func markRefinedOnce(_ record: MemoryRecord) {
        var markers = sourceMarkers(for: record)
        if markers.contains(Self.refinedOnceSourceMarker) {
            return
        }
        markers.remove(Self.pendingAISummarySourceMarker)
        markers.insert(Self.refinedOnceSourceMarker)
        record.sourceID = markers.joined(separator: "|")
        try? context.save()
    }

    func hasBeenRefinedOnce(_ record: MemoryRecord) -> Bool {
        sourceMarkers(for: record).contains(Self.refinedOnceSourceMarker)
    }

    func markPendingAISummary(_ record: MemoryRecord) {
        var markers = sourceMarkers(for: record)
        markers.insert(Self.pendingAISummarySourceMarker)
        record.sourceID = markers.joined(separator: "|")
        try? context.save()
    }

    func hasPendingAISummary(_ record: MemoryRecord) -> Bool {
        sourceMarkers(for: record).contains(Self.pendingAISummarySourceMarker)
    }

    private func sourceMarkers(for record: MemoryRecord) -> Set<String> {
        Set(
            (record.sourceID ?? "")
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
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
        let records = fetch(scope: scope).filter {
            $0.sourceID == sourceID
                || $0.sourceID?.hasPrefix("\(sourceID)|") == true
                || $0.sourceID?.components(separatedBy: "|").contains(sourceID) == true
        }
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

    private func fetchRaw(scope: MemoryScope) -> [MemoryRecord] {
        let raw = scope.rawValue
        let descriptor = FetchDescriptor<MemoryRecord>(
            predicate: #Predicate { $0.scopeRaw == raw },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
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
        let searchContent = record.embeddingText
        let backfillKey = [
            scope.rawValue,
            sourceID ?? "",
            normalized(content)
        ].joined(separator: "|")
        guard scheduledEmbeddingBackfillKeys.insert(backfillKey).inserted else { return }
        let variantTexts = Dictionary(
            uniqueKeysWithValues: MemoryEmbeddingAspect.allCases.map {
                ($0, record.embeddingText(for: $0))
            }
        )
        Task.detached(priority: .utility) {
            let embedding = MemoryEmbedder.shared.embed(searchContent)
            let variantEmbeddings = variantTexts.reduce(into: [MemoryEmbeddingAspect: [Float]]()) { result, item in
                if let vector = MemoryEmbedder.shared.embed(item.value) {
                    result[item.key] = vector
                }
            }
            await MainActor.run {
                MemoryStore.shared.updateEmbedding(
                    scope: scope,
                    sourceID: sourceID,
                    content: content,
                    embedding: embedding
                )
                MemoryStore.shared.updateEmbeddingVariants(
                    scope: scope,
                    sourceID: sourceID,
                    content: content,
                    embeddings: variantEmbeddings
                )
                MemoryStore.shared.scheduledEmbeddingBackfillKeys.remove(backfillKey)
            }
        }
    }

    private func apply(_ metadata: MemoryRecordMetadata, to record: MemoryRecord) {
        record.topicsRaw = metadata.topics.joined(separator: "|")
        record.entitiesRaw = metadata.entities.joined(separator: "|")
        record.meaningSignalsRaw = metadata.meaningSignals.joined(separator: "|")
        record.emotionalToneRaw = metadata.emotionalTone
        record.importanceScore = metadata.importanceScore
        record.semanticContext = metadata.semanticContext
    }

    private func clearEmbeddingVariants(for record: MemoryRecord) {
        record.literalEmbeddingData = Data()
        record.topicalEmbeddingData = Data()
        record.emotionalEmbeddingData = Data()
        record.preferenceEmbeddingData = Data()
        record.identityEmbeddingData = Data()
    }

    private func hydrateMetadataIfNeeded(_ records: [MemoryRecord]) -> [MemoryRecord] {
        var changed = false
        for record in records {
            if record.semanticContext.isEmpty {
                let metadata = MemoryMetadataBuilder.build(
                    content: record.content,
                    kind: record.kind,
                    categoryKey: record.categoryRaw,
                    title: record.title
                )
                apply(metadata, to: record)
                changed = true
            }

            if record.embeddingData.isEmpty || !record.hasEmbeddingVariants {
                scheduleRecordEmbedding(record: record, content: record.content)
            }
        }
        if changed {
            try? context.save()
        }
        return records
    }

    private func hubSummary(for records: [MemoryRecord]) -> String {
        records.prefix(12).map { record in
            record.content
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"(?m)^\s*[-•]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
            return text.contains("book") ? .book : .writing
        }
        if text.contains("podcast") || text.contains("episode") || text.contains("show") {
            return .podcast
        }
        if text.contains("music") || text.contains("song") || text.contains("album") || text.contains("artist") {
            return .music
        }
        if text.contains("faith") || text.contains("belief") || text.contains("god") ||
            text.contains("religion") || text.contains("bible") || text.contains("scripture") {
            return .belief
        }
        if text.contains("security") || text.contains("sop") || text.contains("investigation") ||
            text.contains("threat") || text.contains("risk") {
            return .securityWork
        }
        if text.contains("code") || text.contains("software") || text.contains("technical") ||
            text.contains("swift") || text.contains("xcode") {
            return .technical
        }
        if text.contains("business") || text.contains("company") || text.contains("store") ||
            text.contains("startup") || text.contains("brand") {
            return .business
        }
        if text.contains("project") || text.contains("app") || text.contains("dominus") ||
            text.contains("ai assistant") {
            return text.contains("dominus") || text.contains("ios") || text.contains("app") ? .appDevelopment : .projects
        }
        if text.contains("creative") || text.contains("design") || text.contains("story") {
            return .creative
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
            return text.contains("location") || text.contains("lives") ? .location : .identity
        }
        if text.contains("friend") || text.contains("wife") || text.contains("family") ||
            text.contains("relationship") || text.contains("team") {
            return .relationship
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
        case .identity:        return "person.crop.circle"
        case .profile:         return "person.text.rectangle"
        case .project:         return "folder"
        case .writing:         return "pencil.and.scribble"
        case .business:        return "briefcase"
        case .projects:        return "folder"
        case .goals:           return "target"
        case .belief:          return "book.closed"
        case .technical:       return "cpu"
        case .creative:        return "paintpalette"
        case .file:            return "doc.text"
        case .relationship:    return "person.2"
        case .location:        return "mappin.and.ellipse"
        case .securityWork:    return "shield"
        case .podcast:         return "mic"
        case .book:            return "books.vertical"
        case .music:           return "music.note"
        case .appDevelopment:  return "app.connected.to.app.below.fill"
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
        case .tasks, .project, .projects, .appDevelopment:
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
