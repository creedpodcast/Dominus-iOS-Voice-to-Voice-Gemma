import Foundation
import Combine
import SwiftLlama

struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
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
    @Published var selectedID: UUID?
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

    private let engine = GemmaEngine()

    /// Core identity — kept intentionally short to conserve token budget.
    private let systemPrompt = "You are Dominus — a friendly but curious AI Assistant."
    
    /// Keep only the last 4 turns (8 messages) of raw conversation in the prompt.
    /// Older context is covered by RAG memory retrieval instead.
    private let maxTurnsToKeep = 4

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
        saveToDisk()
    }

    /// Stops the current generation and any in-progress speech immediately.
    func stopGeneration() {
        generationTask?.cancel()
        SpeechManager.shared.stopAndClear()
    }

    /// Non-async entry point — cancels any in-progress generation instantly, then starts fresh.
    func send(_ userText: String) {
        generationTask?.cancel()
        generationTask = Task { await _send(userText) }
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
            let stream = try await engine.streamChat(llmMessages, temperature: 0.7, seed: UInt32.random(in: 1 ... UInt32.max))

            let placeholder = ChatMessage(role: .assistant, content: "")
            conversations[convoIndex].messages.append(placeholder)

            let assistantIndex = conversations[convoIndex].messages.count - 1
            let assistantID    = conversations[convoIndex].messages[assistantIndex].id
            let assistantTS    = conversations[convoIndex].messages[assistantIndex].timestamp

            var assistantText  = ""
            var ttsBuffer      = ""
            var didEnqueueTTS  = false   // tracks whether TTS was actually triggered

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

                    // Speak at natural sentence boundaries only — sounds human, not robotic
                    let sentenceEnded = ttsBuffer.last == "." || ttsBuffer.last == "?" || ttsBuffer.last == "!"
                    // Safety fallback: flush if a very long clause has no punctuation
                    let tooLong = ttsBuffer.count >= 200

                    if sentenceEnded || tooLong {
                        // Clean artifacts from TTS buffer before speaking
                        let chunk = cleanLlamaArtifacts(ttsBuffer)
                        if !chunk.isEmpty {
                            SpeechManager.shared.enqueue(chunk)
                            didEnqueueTTS = true
                        }
                        ttsBuffer = ""
                    }
                }
            }

            if voiceEnabled && !ttsBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let finalChunk = cleanLlamaArtifacts(ttsBuffer)
                if !finalChunk.isEmpty {
                    SpeechManager.shared.enqueue(finalChunk)
                    didEnqueueTTS = true
                }
            }

            // If nothing was enqueued (e.g. entire response was a llama artifact like
            // "### Using cached processing"), onAllSpeechFinished will never fire.
            // Notify the speech manager manually so STT restarts.
            if voiceEnabled && !didEnqueueTTS {
                SpeechManager.shared.onAllSpeechFinished?()
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
            "Using cached processing",
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
        // Collapse multiple blank lines left behind by stripped tokens
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keep system message + last N turns (each turn = 1 user + 1 assistant message).
    /// IMPORTANT: The tail must always start with a user message.
    /// SwiftLlama merges the system message into the first user turn for Gemma's chat
    /// template. If the tail starts with an assistant message, the system prompt lands
    /// in the wrong place and the prompt begins with <start_of_turn>model — which causes
    /// Gemma to immediately predict <end_of_turn> and generate nothing.
    private func trimLLMHistory(_ llm: [LlamaChatMessage]) -> [LlamaChatMessage] {
        let maxMessages = 1 + (maxTurnsToKeep * 2)
        if llm.count <= maxMessages { return llm }
        var tail = Array(llm.suffix(maxMessages - 1))
        // Drop any leading assistant messages so the tail always starts user → assistant
        while tail.first?.role == .assistant { tail.removeFirst() }
        return [llm[0]] + tail
    }

    /// Auto-title a new conversation from the first user message.
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
