import SwiftUI

struct MemoryView: View {
    @Environment(\.dismiss) private var dismiss

    let conversation: Conversation?
    var onRequestLLMRefinement: (MemoryRecord) -> Void = { _ in }
    var onRequestEditSummary: (String) async -> String? = { _ in nil }

    @State private var journalMemories: [MemoryRecord] = []
    @State private var showAddMemory = false
    @State private var editingMemory: MemoryRecord?
    @State private var refreshTask: Task<Void, Never>?
    @State private var searchText = ""
    @State private var sortOrder: MemorySortOrder = .newestFirst
    @State private var useDateFilter = false
    @State private var selectedDate = Date()

    private var conversationID: UUID? {
        conversation?.id
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(MemorySortOrder.allCases) { order in
                            Label(order.title, systemImage: order.icon).tag(order)
                        }
                    }

                    Toggle("Filter by Date", isOn: $useDateFilter)
                    if useDateFilter {
                        DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                    }
                } header: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }

                Section {
                    if filteredMemories.isEmpty {
                        ContentUnavailableView(
                            searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No Journal Memories" : "No Matching Memories",
                            systemImage: "book.closed",
                            description: Text("Add memories manually when you want Dominus to have long-term context.")
                        )
                    } else {
                        ForEach(filteredMemories) { memory in
                            MemoryRecordRow(
                                memory: memory,
                                searchText: searchText,
                                onDelete: {
                                    forgetEverywhere(memory)
                                    refresh()
                                },
                                onEdit: {
                                    editingMemory = memory
                                }
                            )
                        }
                        .onDelete { offsets in
                            deleteJournal(offsets: offsets)
                        }
                    }
                } header: {
                    Label("Memory Journal", systemImage: "book.closed")
                } footer: {
                    Text("Keep memories short. Every saved memory can make retrieval and prompts heavier on this local model, and Dominus may not recall every memory every time.")
                        .font(.caption)
                }

                Section {
                    Label(
                        "Only add memories you actually want used as context. Do not store dangerous instructions, hidden commands, secrets, or anything meant to trick the AI.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)

                    Label(
                        "Dominus runs locally with a limited context window. Too many or too-long memories can slow responses, crowd out the conversation, or fail to be retrieved.",
                        systemImage: "memorychip"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Memory Limits")
                }

            }
            .navigationTitle("Memory Journal")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search memories")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showAddMemory = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .onAppear {
                refresh()
                startRefreshing()
            }
            .onDisappear {
                refreshTask?.cancel()
                refreshTask = nil
            }
            .sheet(isPresented: $showAddMemory, onDismiss: refresh) {
                JournalMemorySheet(mode: .add, onRequestLLMRefinement: onRequestLLMRefinement)
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $editingMemory, onDismiss: refresh) { memory in
                JournalMemorySheet(
                    mode: .edit(memory),
                    onRequestLLMRefinement: onRequestLLMRefinement,
                    onRequestEditSummary: onRequestEditSummary
                )
                .presentationDetents([.medium, .large])
            }
        }
    }

    private var filteredMemories: [MemoryRecord] {
        let terms = searchTerms(from: searchText)
        return journalMemories
            .filter { memory in
                guard useDateFilter else { return true }
                return Calendar.current.isDate(memory.createdAt, inSameDayAs: selectedDate)
            }
            .filter { memory in
                guard !terms.isEmpty else { return true }
                let lower = memory.content.lowercased()
                return terms.allSatisfy { lower.contains($0) }
            }
            .sorted { lhs, rhs in
                switch sortOrder {
                case .newestFirst:
                    return lhs.createdAt > rhs.createdAt
                case .oldestFirst:
                    return lhs.createdAt < rhs.createdAt
                }
            }
    }

    private func refresh() {
        journalMemories = MemoryStore.shared.fetch(scope: .longTerm)
    }

    private func deleteJournal(offsets: IndexSet) {
        offsets.forEach { offset in
            let memories = filteredMemories
            guard memories.indices.contains(offset) else { return }
            forgetEverywhere(memories[offset])
        }
        refresh()
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                refresh()
            }
        }
    }

    private func forgetEverywhere(_ memory: MemoryRecord) {
        MemoryStore.shared.deleteMatching(content: memory.content)
    }

    private func searchTerms(from text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private enum MemorySortOrder: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newestFirst: return "Newest to Oldest"
        case .oldestFirst: return "Oldest to Newest"
        }
    }

    var icon: String {
        switch self {
        case .newestFirst: return "arrow.down"
        case .oldestFirst: return "arrow.up"
        }
    }
}

private enum MemoryTab: String, CaseIterable, Identifiable {
    case hub
    case temporary
    case longTerm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hub:       return "Hub"
        case .temporary: return "Temporary"
        case .longTerm:  return "Blocks"
        }
    }

    var icon: String {
        switch self {
        case .hub:       return "point.3.connected.trianglepath.dotted"
        case .temporary: return "clock.arrow.circlepath"
        case .longTerm:  return "square.stack.3d.up"
        }
    }

    var footer: String {
        switch self {
        case .hub:
            return "The hub is the centralized category map built from editable memory blocks."
        case .temporary:
            return "Current-chat memory is deleted when this chat is deleted. It helps Dominus recall older parts of the active conversation."
        case .longTerm:
            return "Blocks are editable long-term memories. The Hub organizes and summarizes these blocks."
        }
    }
}

private struct MemoryHubRow: View {
    let category: MemoryCategoryInfo
    let hub: MemoryHubRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(category.title, systemImage: category.icon)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(hub?.sourceCount ?? 0)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(.systemGray5), in: Capsule())
            }

            if let hub {
                Text(hub.summary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(6)
            } else {
                Text("No memories in this category yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Label("Open category", systemImage: "chevron.right.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct MemoryRecordRow: View {
    let memory: MemoryRecord
    var searchText: String = ""
    var onAccept: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(memory.kind.promptLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(memory.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            highlightedText(displayContent, query: searchText)
                .font(.callout)
                .textSelection(.enabled)

            if MemoryStore.shared.hasPendingAISummary(memory) {
                Label(
                    "Dominus is processing this memory request and will summarize it for app efficiency.",
                    systemImage: "hourglass"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if MemoryStore.shared.hasBeenRefinedOnce(memory) {
                Label("AI summary completed.", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !metadataSummary.isEmpty {
                Text(metadataSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            if memory.kind == .memoryCandidate {
                HStack {
                    Button {
                        onAccept?()
                    } label: {
                        Label("Accept", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        onDelete?()
                    } label: {
                        Label("Delete", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.caption)
            } else if onDelete != nil {
                HStack {
                    if let onEdit {
                        Button {
                            onEdit()
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .buttonStyle(.bordered)
                    }

                    if let onDelete {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private var displayContent: String {
        memory.content
            .replacingOccurrences(of: #"(?m)^\s*[-•]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var metadataSummary: String {
        let topics = memory.topics.prefix(4).joined(separator: ", ")
        let entities = memory.entities.prefix(3).joined(separator: ", ")
        let signals = memory.meaningSignals.prefix(3).joined(separator: ", ")
        let tone = memory.emotionalToneRaw
        let importance = String(format: "%.2f", memory.importanceScore)
        let parts = [
            topics.isEmpty ? nil : "Topics: \(topics)",
            entities.isEmpty ? nil : "Entities: \(entities)",
            signals.isEmpty ? nil : "Signals: \(signals)",
            tone.map { "Tone: \($0)" },
            "Embeddings: \(memory.embeddingVariantCount)/\(MemoryEmbeddingAspect.allCases.count)",
            "Importance: \(importance)"
        ].compactMap { $0 }
        return parts.joined(separator: "  ")
    }

    private func highlightedText(_ text: String, query: String) -> Text {
        let terms = query.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return Text(text) }

        var attributed = AttributedString(text)
        let lower = text.lowercased()
        for term in terms {
            var searchStart = lower.startIndex
            while let range = lower.range(of: term, range: searchStart..<lower.endIndex) {
                if let start = AttributedString.Index(range.lowerBound, within: attributed),
                   let end = AttributedString.Index(range.upperBound, within: attributed) {
                    attributed[start..<end].backgroundColor = .yellow.opacity(0.35)
                    attributed[start..<end].foregroundColor = .primary
                }
                searchStart = range.upperBound
            }
        }
        return Text(attributed)
    }
}

enum UserMemoryFormatter {
    static func memoryContent(from rawContent: String) -> String {
        let clean = rawContent
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return clean }

        let summarized = MemorySummaryBuilder.summary(from: clean, maxItems: 3) ?? clean
        let compact = summarized
            .components(separatedBy: .newlines)
            .map {
                $0.replacingOccurrences(of: #"^\s*[-•]\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")

        return describeUserMemory(compact.isEmpty ? clean : compact)
    }

    private static func describeUserMemory(_ text: String) -> String {
        let profileName = ProfileStore.shared.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = profileName.isEmpty ? "The user" : profileName
        var memory = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        let replacements: [(String, String)] = [
            (#"(?i)^i\s+am\s+"#, "\(subject) is "),
            (#"(?i)^i'm\s+"#, "\(subject) is "),
            (#"(?i)^i\s+have\s+"#, "\(subject) has "),
            (#"(?i)^i\s+like\s+"#, "\(subject) likes "),
            (#"(?i)^i\s+love\s+"#, "\(subject) loves "),
            (#"(?i)^i\s+prefer\s+"#, "\(subject) prefers "),
            (#"(?i)^i\s+want\s+"#, "\(subject) wants "),
            (#"(?i)^i\s+need\s+"#, "\(subject) needs "),
            (#"(?i)^my\s+"#, "\(subject)'s "),
            (#"(?i)^me\s+"#, "\(subject) ")
        ]

        for (pattern, replacement) in replacements {
            if memory.range(of: pattern, options: .regularExpression) != nil {
                memory = memory.replacingOccurrences(
                    of: pattern,
                    with: replacement,
                    options: .regularExpression
                )
                return finish(memory)
            }
        }

        let lower = memory.lowercased()
        if lower.hasPrefix(subject.lowercased()) || lower.hasPrefix("the user ") {
            return finish(memory)
        }
        return finish("\(subject) said \(lowercaseFirst(memory))")
    }

    private static func finish(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let punctuated = trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?")
            ? trimmed
            : "\(trimmed)."
        return String(punctuated.prefix(1)).uppercased() + String(punctuated.dropFirst())
    }

    private static func lowercaseFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

private struct JournalMemorySheet: View {
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    var onRequestLLMRefinement: (MemoryRecord) -> Void = { _ in }
    var onRequestEditSummary: (String) async -> String? = { _ in nil }

    @State private var content: String
    @State private var summaryDraft = ""
    @State private var isSummarizing = false
    @State private var hasRequestedEditSummary = false
    @State private var summaryError: String?

    enum Mode {
        case add
        case edit(MemoryRecord)

        var navigationTitle: String {
            switch self {
            case .add:
                return "Add Memory"
            case .edit:
                return "Edit Memory"
            }
        }
    }

    init(
        mode: Mode,
        onRequestLLMRefinement: @escaping (MemoryRecord) -> Void = { _ in },
        onRequestEditSummary: @escaping (String) async -> String? = { _ in nil }
    ) {
        self.mode = mode
        self.onRequestLLMRefinement = onRequestLLMRefinement
        self.onRequestEditSummary = onRequestEditSummary
        switch mode {
        case .add:
            _content = State(initialValue: "")
        case .edit(let memory):
            _content = State(initialValue: memory.content)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $content)
                        .frame(minHeight: 180)
                } header: {
                    Text("Memory")
                } footer: {
                    Text(footerText)
                }

                if case .edit = mode {
                    Section {
                        if isSummarizing {
                            HStack {
                                ProgressView()
                                Text("Creating AI summary...")
                                    .foregroundStyle(.secondary)
                            }
                        } else if summaryDraft.isEmpty {
                            Button {
                                requestEditSummary()
                            } label: {
                                Label("Generate Summary", systemImage: "wand.and.sparkles")
                            }
                            .disabled(
                                hasRequestedEditSummary ||
                                content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                        } else {
                            Text(summaryDraft)
                                .font(.callout)
                                .textSelection(.enabled)

                            HStack {
                                Button {
                                    acceptEditSummary()
                                } label: {
                                    Label("Accept Summary", systemImage: "checkmark.circle")
                                }
                                .buttonStyle(.borderedProminent)

                                Button {
                                    regenerateEditSummary()
                                } label: {
                                    Label("Regenerate", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                            }
                            .font(.caption)
                        }

                        if let summaryError {
                            Text(summaryError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } header: {
                        Text("AI Edited Version")
                    } footer: {
                        Text("Accepting replaces the saved memory above. Regenerate asks AI to rewrite it again before you accept.")
                    }
                }
            }
            .navigationTitle(mode.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: content) { _ in
                guard case .edit = mode else { return }
                summaryDraft = ""
                hasRequestedEditSummary = false
                summaryError = nil
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveButtonTitle) {
                        save()
                        dismiss()
                    }
                    .disabled(saveDisabled)
                }
            }
        }
    }

    private var footerText: String {
        switch mode {
        case .add:
            return "Dominus will shorten this automatically and describe it using your profile name when one is set."
        case .edit:
            return "Edit the memory, then create one AI summary. Accepting the summary updates the saved memory."
        }
    }

    private var saveButtonTitle: String {
        switch mode {
        case .add: return "Save"
        case .edit: return "Close"
        }
    }

    private var saveDisabled: Bool {
        switch mode {
        case .add:
            return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .edit:
            return false
        }
    }

    private func save() {
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let summarizedContent = UserMemoryFormatter.memoryContent(from: cleanContent)

        switch mode {
        case .add:
            let saved = MemoryRetriever.shared.rememberLongTerm(
                kind: .userFact,
                title: nil,
                content: summarizedContent,
                sourceID: "manual:\(UUID().uuidString)",
                categoryKey: MemoryHubCategory.profile.rawValue
            )
            saved.forEach(onRequestLLMRefinement)
        case .edit(let memory):
            return
        }
    }

    private func requestEditSummary() {
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanContent.isEmpty, !hasRequestedEditSummary else { return }
        hasRequestedEditSummary = true
        isSummarizing = true
        summaryError = nil

        Task { @MainActor in
            let summary = await summaryWithTimeout(for: cleanContent)
            isSummarizing = false
            if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                summaryDraft = summary
            } else {
                hasRequestedEditSummary = false
                summaryError = "Dominus could not create a summary right now. Try editing again later."
            }
        }
    }

    private func regenerateEditSummary() {
        summaryDraft = ""
        hasRequestedEditSummary = false
        summaryError = nil
        requestEditSummary()
    }

    private func summaryWithTimeout(for content: String) async -> String? {
        await withTaskGroup(of: String?.self, returning: String?.self) { group in
            group.addTask {
                await onRequestEditSummary(content)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                return UserMemoryFormatter.memoryContent(from: content)
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func acceptEditSummary() {
        guard case let .edit(memory) = mode else { return }
        let cleanSummary = summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSummary.isEmpty else { return }

        MemoryStore.shared.update(
            memory,
            kind: memory.kind,
            title: nil,
            content: cleanSummary,
            categoryKey: memory.categoryRaw
        )
        MemoryStore.shared.markRefinedOnce(memory)
        dismiss()
    }
}

private struct MemoryHubDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let category: MemoryCategoryInfo
    let categories: [MemoryCategoryInfo]
    var onRequestLLMRefinement: (MemoryRecord) -> Void = { _ in }

    @State private var sourceMemories: [MemoryRecord] = []
    @State private var hubSummary = ""
    @State private var showAddMemory = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if hubSummary.isEmpty {
                        Text("No summary yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(hubSummary)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                } header: {
                    Label("Hub Summary", systemImage: category.icon)
                }

                Section {
                    if sourceMemories.isEmpty {
                        ContentUnavailableView(
                            "No Source Memories",
                            systemImage: category.icon,
                            description: Text("Add a memory to this category to build the hub.")
                        )
                    } else {
                        ForEach(sourceMemories) { memory in
                            MemoryRecordRow(
                                memory: memory,
                                onDelete: {
                                    forgetEverywhere(memory)
                                    refresh()
                                }
                            )
                        }
                        .onDelete { offsets in
                            delete(offsets: offsets)
                        }
                    }
                } header: {
                    Text("Memories")
                } footer: {
                    Text("Delete a memory and add a new one if it needs to change.")
                }
            }
            .navigationTitle(category.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showAddMemory = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .onAppear(perform: refresh)
            .sheet(isPresented: $showAddMemory, onDismiss: refresh) {
                AddMemorySheet(
                    defaultTab: .longTerm,
                    conversationID: nil,
                    categories: categories,
                    presetTitle: category.title,
                    presetKind: category.defaultKind,
                    presetCategoryKey: category.id,
                    onRequestLLMRefinement: onRequestLLMRefinement
                )
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func refresh() {
        sourceMemories = MemoryStore.shared.fetchHubSourceRecords(categoryKey: category.id)
        hubSummary = MemoryStore.shared.fetchHubRecords()
            .first { $0.categoryRaw == category.id }?
            .summary ?? ""
    }

    private func delete(offsets: IndexSet) {
        offsets.forEach { offset in
            guard sourceMemories.indices.contains(offset) else { return }
            forgetEverywhere(sourceMemories[offset])
        }
        refresh()
    }

    private func forgetEverywhere(_ memory: MemoryRecord) {
        MemoryStore.shared.deleteMatching(content: memory.content)
    }
}

private struct EmptyMemoryView: View {
    let tab: MemoryTab

    var body: some View {
        ContentUnavailableView(
            "No \(tab.title) Memory",
            systemImage: tab.icon,
            description: Text(description)
        )
    }

    private var description: String {
        if tab == .hub {
            return "The hub will appear after memory blocks are saved."
        }
        return "Tap plus to add one manually, or keep chatting so Dominus can create memory automatically."
    }
}

private struct AddMemorySheet: View {
    @Environment(\.dismiss) private var dismiss

    let defaultTab: MemoryTab
    let conversationID: UUID?
    let categories: [MemoryCategoryInfo]
    let presetTitle: String?
    let presetKind: MemoryKind?
    let presetCategoryKey: String?
    var onRequestLLMRefinement: (MemoryRecord) -> Void

    @State private var tab: MemoryTab
    @State private var content = ""
    @State private var longTermKind: MemoryKind = .userFact
    @State private var categoryKey: String
    @State private var savedCount = 0

    init(
        defaultTab: MemoryTab,
        conversationID: UUID?,
        categories: [MemoryCategoryInfo],
        presetTitle: String? = nil,
        presetKind: MemoryKind? = nil,
        presetCategoryKey: String? = nil,
        onRequestLLMRefinement: @escaping (MemoryRecord) -> Void = { _ in }
    ) {
        self.defaultTab = defaultTab
        self.conversationID = conversationID
        self.categories = categories
        self.presetTitle = presetTitle
        self.presetKind = presetKind
        self.presetCategoryKey = presetCategoryKey
        self.onRequestLLMRefinement = onRequestLLMRefinement
        _tab = State(initialValue: defaultTab)
        _longTermKind = State(initialValue: presetKind ?? .userFact)
        _categoryKey = State(initialValue: presetCategoryKey ?? MemoryStore.uncategorizedCategoryKey)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Memory Type", selection: $tab) {
                        if conversationID != nil {
                            Text("Temporary").tag(MemoryTab.temporary)
                        }
                        Text("Block").tag(MemoryTab.longTerm)
                    }
                }

                if tab == .longTerm {
                    Section("Category") {
                        if tab == .longTerm {
                            Picker("Category", selection: $longTermKind) {
                                Text("User Fact").tag(MemoryKind.userFact)
                                Text("Preference").tag(MemoryKind.preference)
                                Text("Goal").tag(MemoryKind.goal)
                                Text("Task Reference").tag(MemoryKind.taskReference)
                                Text("App Instruction").tag(MemoryKind.appInstruction)
                            }
                        }

                        Picker("Hub", selection: $categoryKey) {
                            ForEach(categories) { category in
                                Label(category.title, systemImage: category.icon).tag(category.id)
                            }
                        }
                    }
                }

                Section {
                    TextEditor(text: $content)
                        .frame(minHeight: 140)
                } header: {
                    Text("Memory")
                } footer: {
                    Text("Dominus will shorten this automatically and describe it using your profile name when one is set.")
                }

                Section {
                    Button {
                        addMemory()
                        resetDraft()
                    } label: {
                        Label("Save and Add Another", systemImage: "plus.circle")
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    if savedCount > 0 {
                        Text("\(savedCount) saved in this session.")
                    }
                }
            }
            .navigationTitle("Add Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(savedCount > 0 ? "Done" : "Add") {
                        if savedCount == 0 {
                            addMemory()
                        }
                        dismiss()
                    }
                    .disabled(savedCount == 0 && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func addMemory() {
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let summarizedContent = UserMemoryFormatter.memoryContent(from: cleanContent)

        switch tab {
        case .hub:
            return
        case .temporary:
            guard let conversationID else { return }
            MemoryRetriever.shared.rememberConversationNote(
                conversationID: conversationID,
                title: nil,
                content: summarizedContent
            )
        case .longTerm:
            let saved = MemoryRetriever.shared.rememberLongTerm(
                kind: longTermKind,
                title: nil,
                content: summarizedContent,
                sourceID: "manual:\(UUID().uuidString)",
                categoryKey: categoryKey
            )
            saved.forEach(onRequestLLMRefinement)
        }

        savedCount += 1
    }

    private func resetDraft() {
        content = ""
        categoryKey = presetCategoryKey ?? MemoryStore.uncategorizedCategoryKey
    }
}

private struct AddCategorySheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Category Name") {
                    TextField("Example: Faith Notes", text: $title)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("New Hub Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        _ = MemoryStore.shared.addCustomCategory(title: title)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
