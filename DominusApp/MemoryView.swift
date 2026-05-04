import SwiftUI

struct MemoryView: View {
    @Environment(\.dismiss) private var dismiss

    let conversation: Conversation?

    @State private var pendingSuggestions: [MemoryRecord] = []
    @State private var journalMemories: [MemoryRecord] = []
    @State private var showAddMemory = false
    @State private var editingMemory: MemoryRecord?
    @State private var refreshTask: Task<Void, Never>?

    private var conversationID: UUID? {
        conversation?.id
    }

    var body: some View {
        NavigationStack {
            List {
                if !pendingSuggestions.isEmpty {
                    Section {
                        ForEach(pendingSuggestions) { memory in
                            MemoryRecordRow(
                                memory: memory,
                                onAccept: {
                                    accept(memory)
                                },
                                onDelete: {
                                    forgetEverywhere(memory)
                                    refresh()
                                }
                            )
                        }
                    } header: {
                        Label("Suggested Memories", systemImage: "lightbulb")
                    } footer: {
                        Text("These are not part of the journal until you accept them.")
                    }
                }

                Section {
                    if journalMemories.isEmpty {
                        ContentUnavailableView(
                            "No Journal Memories",
                            systemImage: "book.closed",
                            description: Text("Add one manually, say \"remember this\", or accept a suggested memory from chat.")
                        )
                    } else {
                        ForEach(journalMemories) { memory in
                            MemoryRecordRow(
                                memory: memory,
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
                    Text("This is the single trusted memory source Dominus searches with RAG. Each entry stays editable and deletable.")
                        .font(.caption)
                }
            }
            .navigationTitle("Memory Journal")
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
            .onAppear {
                refresh()
                startRefreshing()
            }
            .onDisappear {
                refreshTask?.cancel()
                refreshTask = nil
            }
            .sheet(isPresented: $showAddMemory, onDismiss: refresh) {
                JournalMemorySheet(mode: .add)
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $editingMemory, onDismiss: refresh) { memory in
                JournalMemorySheet(mode: .edit(memory))
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func refresh() {
        if let conversationID {
            pendingSuggestions = MemoryStore.shared.fetch(conversationID: conversationID)
                .filter { $0.kind == .memoryCandidate }
        } else {
            pendingSuggestions = []
        }
        journalMemories = MemoryStore.shared.fetch(scope: .longTerm)
    }

    private func deleteJournal(offsets: IndexSet) {
        offsets.forEach { offset in
            guard journalMemories.indices.contains(offset) else { return }
            forgetEverywhere(journalMemories[offset])
        }
        refresh()
    }

    private func accept(_ memory: MemoryRecord) {
        MemoryRetriever.shared.acceptCandidate(memory)
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
        ProfileStore.shared.deleteFactsMatching(memoryText: memory.content)
    }
}

private enum MemoryTab: String, CaseIterable, Identifiable {
    case hub
    case trace
    case temporary
    case longTerm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hub:       return "Hub"
        case .trace:     return "Trace"
        case .temporary: return "Temporary"
        case .longTerm:  return "Blocks"
        }
    }

    var icon: String {
        switch self {
        case .hub:       return "point.3.connected.trianglepath.dotted"
        case .trace:     return "waveform.path.ecg"
        case .temporary: return "clock.arrow.circlepath"
        case .longTerm:  return "square.stack.3d.up"
        }
    }

    var footer: String {
        switch self {
        case .hub:
            return "The hub is the centralized category map built from editable memory blocks."
        case .trace:
            return "Trace shows the latest memory search and context pack sent into the AI."
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
                Text(memory.updatedAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let title = memory.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }

            Text(memory.content)
                .font(.callout)
                .textSelection(.enabled)

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
            } else if onEdit != nil || onDelete != nil {
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
}

private struct JournalMemorySheet: View {
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var title: String
    @State private var content: String

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

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .add:
            _title = State(initialValue: "")
            _content = State(initialValue: "")
        case .edit(let memory):
            _title = State(initialValue: memory.title ?? "")
            _content = State(initialValue: memory.content)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Optional title", text: $title)
                        .autocorrectionDisabled()
                } header: {
                    Text("Title")
                }

                Section {
                    TextEditor(text: $content)
                        .frame(minHeight: 180)
                } header: {
                    Text("Memory")
                } footer: {
                    Text("Dominus searches these journal entries when they are relevant to the latest message.")
                }
            }
            .navigationTitle(mode.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let optionalTitle = cleanTitle.isEmpty ? nil : cleanTitle
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .add:
            MemoryRetriever.shared.rememberLongTerm(
                kind: .userFact,
                title: optionalTitle,
                content: cleanContent,
                categoryKey: MemoryStore.uncategorizedCategoryKey
            )
        case .edit(let memory):
            MemoryStore.shared.update(
                memory,
                kind: .userFact,
                title: optionalTitle,
                content: cleanContent,
                categoryKey: MemoryStore.uncategorizedCategoryKey
            )
        }
    }
}

private struct MemoryHubDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let category: MemoryCategoryInfo
    let categories: [MemoryCategoryInfo]

    @State private var sourceMemories: [MemoryRecord] = []
    @State private var hubSummary = ""
    @State private var showAddMemory = false
    @State private var editingMemory: MemoryRecord?

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
                                },
                                onEdit: {
                                    editingMemory = memory
                                }
                            )
                        }
                        .onDelete { offsets in
                            delete(offsets: offsets)
                        }
                    }
                } header: {
                    Text("Editable Memories")
                } footer: {
                    Text("Editing these blocks rebuilds the hub automatically.")
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
                    presetCategoryKey: category.id
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $editingMemory, onDismiss: refresh) { memory in
                EditMemorySheet(memory: memory, categories: categories)
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
        ProfileStore.shared.deleteFactsMatching(memoryText: memory.content)
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
        if tab == .trace {
            return "Ask Dominus a question to see the latest memory search trace."
        }
        return "Tap plus to add one manually, or keep chatting so Dominus can create memory automatically."
    }
}

private struct MemoryTraceHeader: View {
    let query: String
    let updatedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Latest Query")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(query)
                .font(.callout)
                .textSelection(.enabled)
            if let updatedAt {
                Text(updatedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MemoryTraceRow: View {
    let step: MemoryTraceStep

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(step.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(step.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
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

    @State private var tab: MemoryTab
    @State private var title = ""
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
        presetCategoryKey: String? = nil
    ) {
        self.defaultTab = defaultTab
        self.conversationID = conversationID
        self.categories = categories
        self.presetTitle = presetTitle
        self.presetKind = presetKind
        self.presetCategoryKey = presetCategoryKey
        _tab = State(initialValue: defaultTab)
        _title = State(initialValue: presetTitle ?? "")
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

                Section("Title") {
                    TextField("Optional label", text: $title)
                        .autocorrectionDisabled()
                }

                Section("Memory") {
                    TextEditor(text: $content)
                        .frame(minHeight: 140)
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
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let optionalTitle = cleanTitle.isEmpty ? nil : cleanTitle

        switch tab {
        case .hub:
            return
        case .trace:
            return
        case .temporary:
            guard let conversationID else { return }
            MemoryRetriever.shared.rememberConversationNote(
                conversationID: conversationID,
                title: optionalTitle,
                content: cleanContent
            )
        case .longTerm:
            MemoryRetriever.shared.rememberLongTerm(
                kind: longTermKind,
                title: optionalTitle,
                content: cleanContent,
                categoryKey: categoryKey
            )
        }

        savedCount += 1
    }

    private func resetDraft() {
        title = presetTitle ?? ""
        content = ""
        categoryKey = presetCategoryKey ?? MemoryStore.uncategorizedCategoryKey
    }
}

private struct EditMemorySheet: View {
    @Environment(\.dismiss) private var dismiss

    let memory: MemoryRecord
    let categories: [MemoryCategoryInfo]

    @State private var title: String
    @State private var content: String
    @State private var kind: MemoryKind
    @State private var categoryKey: String

    init(memory: MemoryRecord, categories: [MemoryCategoryInfo]) {
        self.memory = memory
        self.categories = categories
        _title = State(initialValue: memory.title ?? "")
        _content = State(initialValue: memory.content)
        _kind = State(initialValue: memory.kind)
        _categoryKey = State(initialValue: memory.categoryRaw ?? MemoryStore.uncategorizedCategoryKey)
    }

    var body: some View {
        NavigationStack {
            Form {
                if memory.scope == .longTerm {
                    Section("Category") {
                        if memory.scope == .longTerm {
                            Picker("Category", selection: $kind) {
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

                Section("Title") {
                    TextField("Optional label", text: $title)
                        .autocorrectionDisabled()
                }

                Section("Memory") {
                    TextEditor(text: $content)
                        .frame(minHeight: 160)
                }
            }
            .navigationTitle("Edit Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let optionalTitle = cleanTitle.isEmpty ? nil : cleanTitle
        let cleanKind = memory.scope == .longTerm ? kind : memory.kind

        if let profileKey = profileKey(from: memory.sourceID) {
            ProfileStore.shared.upsert(
                key: profileKey,
                value: profileValue(from: content, key: profileKey)
            )
            return
        }

        MemoryStore.shared.update(
            memory,
            kind: cleanKind,
            title: optionalTitle,
            content: content,
            categoryKey: memory.scope != .conversation ? categoryKey : memory.categoryRaw
        )
    }

    private func profileKey(from sourceID: String?) -> String? {
        guard let sourceID, sourceID.hasPrefix("profile:") else { return nil }
        let key = String(sourceID.dropFirst("profile:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private func profileValue(from text: String, key: String) -> String {
        let trimmed = text
            .replacingOccurrences(of: "•", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "User \(key):"
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            return String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
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
