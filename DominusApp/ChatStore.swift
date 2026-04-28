import Foundation
import Combine
import SwiftLlama

struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    /// false once the user manually renames — blocks LLM auto-title from overwriting.
    var titleIsAuto: Bool
    /// true once the LLM has produced a title for this conversation. Prevents re-running.
    var hasGeneratedTitle: Bool

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = [],
        titleIsAuto: Bool = true,
        hasGeneratedTitle: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.titleIsAuto = titleIsAuto
        self.hasGeneratedTitle = hasGeneratedTitle
    }

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, messages
        case titleIsAuto, hasGeneratedTitle
    }

    // Custom decoder for backward compatibility with chats saved before these fields existed.
    // Pre-existing chats are treated as already-titled so the LLM doesn't overwrite them on first launch.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        messages = try c.decode([ChatMessage].self, forKey: .messages)
        titleIsAuto = try c.decodeIfPresent(Bool.self, forKey: .titleIsAuto) ?? true
        hasGeneratedTitle = try c.decodeIfPresent(Bool.self, forKey: .hasGeneratedTitle) ?? true
    }
}

extension Conversation {
    /// Format: "4.27.2026 8:20pm" — used in the chat history sidebar.
    /// Locale is pinned to en_US_POSIX so the 12-hour format renders the same
    /// regardless of the device's 24-hour time preference.
    static let startedAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M.d.yyyy h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    var startedAtDisplay: String { Self.startedAtFormatter.string(from: createdAt) }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date

    enum Role: String, Codable {
        case user
        case assistant
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

@MainActor
final class ChatStore: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var selectedID: UUID? {
        didSet {
            // When the user navigates away from a chat, give it an LLM title
            // if it doesn't have one yet. Skip on initial assignment (oldValue == nil).
            guard let old = oldValue, old != selectedID else { return }
            scheduleTitleGeneration(for: old)
        }
    }
    @Published var isGenerating: Bool = false
    @Published var isLoaded: Bool = false
    @Published var isLoading: Bool = false
    @Published var loadStatus: String = "Idle"
    @Published var loadProgress: Double = 0.0

    @Published var voiceEnabled: Bool = false {
        didSet {
            if !voiceEnabled {
                SpeechManager.shared.stopAndClear()
            }
        }
    }

    /// Tracks the current generation so it can be cancelled instantly
    private var generationTask: Task<Void, Never>?
    /// Tracks an in-flight LLM title generation. Cancelled when the user sends a new message
    /// so chat generation always wins over title generation for the single LlamaService instance.
    private var titleTask: Task<Void, Never>?

    private let engine = GemmaEngine()

    /// Core identity — kept intentionally short to conserve token budget.
    private let systemPrompt = "You are Dominus — a friendly but curious AI Assistant."
    
    /// Keep only the last 4 turns (8 messages) of raw conversation in the prompt.
    /// Older context is covered by RAG memory retrieval instead.
    private let maxTurnsToKeep = 10

    private var saveURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conversations.json")
    }

    init() {
        engine.$isLoaded.assign(to: &$isLoaded)
        engine.$isLoading.assign(to: &$isLoading)
        engine.$loadStatus.assign(to: &$loadStatus)
        engine.$loadProgress.assign(to: &$loadProgress)
    }

    func boot() {
        loadFromDisk()
        if conversations.isEmpty {
            let c = Conversation(title: "New Chat")
            conversations = [c]
            selectedID = c.id
            saveToDisk()
        } else if selectedID == nil {
            selectedID = conversations.first?.id
        }
    }

    func loadModelIfNeeded() {
        engine.loadModelIfNeeded()
    }

    func selectedConversation() -> Conversation? {
        guard let id = selectedID else { return nil }
        return conversations.first(where: { $0.id == id })
    }

    private func indexForSelectedConversation() -> Int? {
        guard let id = selectedID else { return nil }
        return conversations.firstIndex(where: { $0.id == id })
    }

    func newConversation() {
        let convo = Conversation(title: "New Chat")
        conversations.insert(convo, at: 0)
        // Assigning selectedID triggers didSet which schedules title gen for the previous chat.
        selectedID = convo.id
        saveToDisk()
    }

    func deleteConversation(_ convo: Conversation) {
        conversations.removeAll { $0.id == convo.id }
        if selectedID == convo.id {
            selectedID = conversations.first?.id
        }
        if conversations.isEmpty {
            newConversation()
        } else {
            saveToDisk()
        }
    }

    func renameConversation(_ convoID: UUID, to newTitle: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == convoID }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        conversations[idx].title = trimmed
        conversations[idx].updatedAt = Date()
        // User has chosen a title — lock it so the LLM never overwrites it.
        conversations[idx].titleIsAuto = false
        conversations[idx].hasGeneratedTitle = true
        saveToDisk()
    }

    /// Stops the current generation without sending anything new.
    func stopGeneration() {
        generationTask?.cancel()
    }

    /// Non-async entry point — cancels any in-progress generation instantly, then starts fresh.
    func send(_ userText: String) {
        // Title generation rides on the same LlamaService — cancel it first and await its
        // unwind so the new chat stream doesn't collide with an in-flight title stream.
        titleTask?.cancel()
        generationTask?.cancel()
        let prevTitle = titleTask
        let prevGen = generationTask
        generationTask = Task { @MainActor [weak self] in
            await prevTitle?.value
            await prevGen?.value
            await self?._send(userText)
        }
    }

    private func _send(_ userText: String) async {
        loadModelIfNeeded()
        guard isLoaded else { return }
        guard let convoIndex = indexForSelectedConversation() else { return }

        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isGenerating = true

        conversations[convoIndex].messages.append(ChatMessage(role: .user, content: trimmed))
        conversations[convoIndex].updatedAt = Date()
        autoTitleIfNeeded(convoIndex: convoIndex, userText: trimmed)
        saveToDisk()

        // ── Auto-extract personal facts from user message ──────────────────
        ProfileStore.shared.extractAndSave(from: trimmed)

        // ── Build LLM context ──────────────────────────────────────────────
        // 1. User profile — always injected first
        let profileBlock = ProfileStore.shared.systemPromptBlock()

        // 2. Retrieve semantically relevant memories for this query
        let memoryContext = MemoryRetriever.shared.retrieve(query: trimmed, topK: 5)

        // 3. Compose full system prompt
        var fullSystemPrompt = systemPrompt
        if !profileBlock.isEmpty {
            fullSystemPrompt += "\n\n\(profileBlock)"
        }
        if !memoryContext.isEmpty {
            fullSystemPrompt += "\n\n\(memoryContext)"
        }

        // 3. Build message list: system + last N turns of raw history
        var llmMessages: [LlamaChatMessage] = [
            .init(role: .system, content: fullSystemPrompt)
        ]
        llmMessages += conversations[convoIndex].messages.map { m in
            switch m.role {
            case .user:      return .init(role: .user,      content: m.content)
            case .assistant: return .init(role: .assistant, content: m.content)
            }
        }
        llmMessages = trimLLMHistory(llmMessages)

        do {
            let stream = try await engine.streamChat(llmMessages, temperature: 0.7, seed: 42)

            let placeholder = ChatMessage(role: .assistant, content: "")
            conversations[convoIndex].messages.append(placeholder)

            let assistantIndex = conversations[convoIndex].messages.count - 1
            let assistantID    = conversations[convoIndex].messages[assistantIndex].id
            let assistantTS    = conversations[convoIndex].messages[assistantIndex].timestamp

            var assistantText = ""
            var ttsBuffer     = ""
            var lastEnqueuedAtCount = 0

            if voiceEnabled {
                SpeechManager.shared.stopAndClear()
            }

            for try await token in stream {
                // Exit immediately if a new message was sent
                try Task.checkCancellation()

                assistantText += token

                let displayText = cleanLlamaArtifacts(assistantText)
                conversations[convoIndex].messages[assistantIndex] = ChatMessage(
                    id: assistantID,
                    role: .assistant,
                    content: displayText,
                    timestamp: assistantTS
                )

                if voiceEnabled {
                    ttsBuffer += token
                    let hitSentenceEnd   = ttsBuffer.last == "." || ttsBuffer.last == "?" || ttsBuffer.last == "!"
                    let hitNewline       = ttsBuffer.contains("\n")
                    let bufferLongEnough = ttsBuffer.count >= 120

                    // Apple TTS synthesizes instantly — small chunks sound better
                    // because each sentence gets its own natural prosody.
                    if ttsBuffer.count >= 40 && (hitSentenceEnd || hitNewline || bufferLongEnough) {
                        SpeechManager.shared.enqueue(ttsBuffer)
                        lastEnqueuedAtCount = assistantText.count
                        ttsBuffer = ""
                    }
                }
            }

            if voiceEnabled && !ttsBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SpeechManager.shared.enqueue(ttsBuffer)
            }

            conversations[convoIndex].updatedAt = Date()
            saveToDisk()

            // ── Store exchange in long-term memory (fire-and-forget) ──────
            let cleanedAssistant = conversations[convoIndex].messages[assistantIndex].content
            if !cleanedAssistant.isEmpty {
                MemoryRetriever.shared.remember(
                    conversationID: conversations[convoIndex].id,
                    userText: trimmed,
                    assistantText: cleanedAssistant
                )
            }

            // ── Schedule LLM title generation (idempotent, no-op if already titled) ──
            scheduleTitleGeneration(for: conversations[convoIndex].id)

        } catch {
            // SwiftLlama throws LlamaError instead of CancellationError when the task
            // is cancelled mid-stream — check Task.isCancelled to handle both cases
            if Task.isCancelled || error is CancellationError {
                // User interrupted — keep partial response, remove empty placeholder
                if let idx = conversations[convoIndex].messages.indices.last,
                   conversations[convoIndex].messages[idx].content.isEmpty {
                    conversations[convoIndex].messages.removeLast()
                }
                SpeechManager.shared.stopAndClear()
            } else {
                conversations[convoIndex].messages.append(
                    ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)")
                )
            }
            conversations[convoIndex].updatedAt = Date()
            saveToDisk()
        }

        isGenerating = false
    }

    // MARK: - Helpers

    private func cleanLlamaArtifacts(_ text: String) -> String {
        let artifacts = [
            "### Using cached processing",
            "### Cached processing",
            "### Cached",
            "<start_of_turn>model",
            "<start_of_turn>user",
            "<start_of_turn>",
            "<end_of_turn>",
            "<bos>",
            "<eos>",
        ]
        var result = text
        for artifact in artifacts {
            result = result.replacingOccurrences(of: artifact, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keep system message + last N turns (each turn = 1 user + 1 assistant message).
    private func trimLLMHistory(_ llm: [LlamaChatMessage]) -> [LlamaChatMessage] {
        let maxMessages = 1 + (maxTurnsToKeep * 2)
        if llm.count <= maxMessages { return llm }
        let tail = llm.suffix(maxMessages - 1)
        return [llm[0]] + tail
    }

    /// Auto-title a new conversation from the first user message.
    /// This is a placeholder — replaced by the LLM-generated title once available.
    private func autoTitleIfNeeded(convoIndex: Int, userText: String) {
        guard conversations[convoIndex].title == "New Chat" else { return }
        let userCount = conversations[convoIndex].messages.filter { $0.role == .user }.count
        guard userCount == 1 else { return }

        // Use up to 7 words; cap at 45 characters so sidebar stays clean
        let words = userText.split(separator: " ").prefix(7).map(String.init)
        guard !words.isEmpty else { return }
        var title = words.joined(separator: " ")
        if title.count > 45 {
            title = String(title.prefix(45)).trimmingCharacters(in: .whitespaces) + "…"
        }
        // Capitalise first letter
        conversations[convoIndex].title = title.prefix(1).uppercased() + title.dropFirst()
    }

    // MARK: - LLM-generated titles

    /// Public exit-trigger. Call when the app backgrounds or the user otherwise leaves a chat
    /// without having sent enough turns for the in-line trigger to have already fired.
    func generateTitleForCurrentIfNeeded() {
        guard let id = selectedID else { return }
        scheduleTitleGeneration(for: id)
    }

    /// Schedule an LLM title generation for the given conversation. Idempotent — bails immediately
    /// if the chat is already titled by the LLM, was renamed by the user, or has no user messages.
    private func scheduleTitleGeneration(for convoID: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == convoID }) else { return }
        let convo = conversations[idx]
        guard convo.titleIsAuto, !convo.hasGeneratedTitle else { return }
        guard convo.messages.contains(where: { $0.role == .user }) else { return }

        // Replace any prior in-flight title task — only one title gen runs at a time.
        titleTask?.cancel()
        titleTask = Task { @MainActor [weak self] in
            await self?._generateLLMTitle(convoID: convoID)
        }
    }

    private func _generateLLMTitle(convoID: UUID) async {
        // Don't fight the chat stream for the LlamaService instance.
        guard !isGenerating else { return }
        guard let idx = conversations.firstIndex(where: { $0.id == convoID }) else { return }
        let convo = conversations[idx]
        guard convo.titleIsAuto, !convo.hasGeneratedTitle else { return }
        guard !convo.messages.isEmpty else { return }
        guard isLoaded else { return }

        // Take up to the first three turns (six messages), trimmed.
        let snippetMax = 220
        let contextLines: String = convo.messages.prefix(6).map { m in
            let label = m.role == .user ? "User" : "Assistant"
            let snippet = String(m.content.prefix(snippetMax))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(label): \(snippet)"
        }.joined(separator: "\n")

        let titleSystem = "You write very short conversation titles. Output ONLY the title — 3 to 5 words, no quotes, no preamble, no trailing punctuation. Be specific to the topic."
        let titleUser = """
        Title this conversation:

        \(contextLines)

        Title:
        """

        isGenerating = true
        defer { isGenerating = false }

        do {
            try Task.checkCancellation()
            let raw = try await engine.generateOnce(
                [
                    .init(role: .system, content: titleSystem),
                    .init(role: .user, content: titleUser),
                ],
                temperature: 0.4,
                seed: 7,
                maxChars: 200
            )
            try Task.checkCancellation()

            guard let cleaned = cleanTitleResponse(raw), !cleaned.isEmpty else { return }

            // Re-find the conversation in case it moved while we awaited.
            guard let writeIdx = conversations.firstIndex(where: { $0.id == convoID }) else { return }
            // Honor manual rename that may have happened while we awaited.
            guard conversations[writeIdx].titleIsAuto,
                  !conversations[writeIdx].hasGeneratedTitle else { return }

            conversations[writeIdx].title = cleaned
            conversations[writeIdx].hasGeneratedTitle = true
            saveToDisk()
        } catch {
            // Cancelled or model error — leave the placeholder title in place;
            // a future exit trigger or chat turn will retry.
        }
    }

    /// Strip llama artifacts, common preamble ("Title:", "Sure! Here's…"), surrounding quotes,
    /// trailing punctuation, and excess length.
    private func cleanTitleResponse(_ raw: String) -> String? {
        var t = cleanLlamaArtifacts(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // Take the first non-empty line.
        if let firstLine = t.split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            t = firstLine.trimmingCharacters(in: .whitespaces)
        }

        // Strip common preamble before a colon ("Title:", "Here's a title:", etc.)
        // Only if the colon is near the start, to avoid eating colons in real titles.
        if let colonIdx = t.firstIndex(of: ":"),
           t.distance(from: t.startIndex, to: colonIdx) < 24 {
            t = String(t[t.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
        }

        // Strip surrounding quote/backtick characters.
        let wrappers: Set<Character> = ["\"", "'", "`", "*"]
        while let f = t.first, wrappers.contains(f) { t.removeFirst() }
        while let l = t.last,  wrappers.contains(l) { t.removeLast() }

        // Strip trailing punctuation.
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?"]
        while let l = t.last, trailing.contains(l) { t.removeLast() }

        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }

        // Cap length for the sidebar.
        if t.count > 45 {
            t = String(t.prefix(45)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return t
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        do {
            let data    = try Data(contentsOf: saveURL)
            let decoded = try JSONDecoder().decode([Conversation].self, from: data)
            conversations = decoded.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            conversations = []
        }
    }

    private func saveToDisk() {
        do {
            let sorted = conversations.sorted { $0.updatedAt > $1.updatedAt }
            let data   = try JSONEncoder().encode(sorted)
            try data.write(to: saveURL, options: [.atomic])
        } catch {
            // no-op — non-fatal
        }
    }
}
