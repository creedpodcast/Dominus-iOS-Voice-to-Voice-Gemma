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
    
    // ✅ NEW: toggle between text-only and text+voice
    @Published var voiceEnabled: Bool = false {
        didSet {
            if voiceEnabled == false {
                SpeechManager.shared.stopAndClear()            }
        }
    }

    private let engine = GemmaEngine()
    private let systemPrompt = "You are a helpful assistant. Keep answers short unless asked."
    private let maxTurnsToKeep = 12

    private var saveURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("conversations.json")
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

    func send(_ userText: String) async {
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

        var llmMessages: [LlamaChatMessage] = [
            .init(role: .system, content: systemPrompt)
        ]

        llmMessages += conversations[convoIndex].messages.map { m in
            switch m.role {
            case .user: return .init(role: .user, content: m.content)
            case .assistant: return .init(role: .assistant, content: m.content)
            }
        }

        llmMessages = trimLLMHistory(llmMessages)

        do {
            let stream = try await engine.streamChat(llmMessages, temperature: 0.7, seed: 42)

            let placeholder = ChatMessage(role: .assistant, content: "")
            conversations[convoIndex].messages.append(placeholder)

            let assistantIndex = conversations[convoIndex].messages.count - 1
            let assistantID = conversations[convoIndex].messages[assistantIndex].id
            let assistantTS = conversations[convoIndex].messages[assistantIndex].timestamp

            var assistantText = ""

            // NEW: streaming TTS chunk buffer
            var ttsBuffer = ""
            var lastEnqueuedAtCount = 0

            // If voice is on, stop any prior speech and clear the queue
            if voiceEnabled {
                SpeechManager.shared.stopAndClear()
            }

            for try await token in stream {
                assistantText += token

                // update UI message as you already do
                conversations[convoIndex].messages[assistantIndex] = ChatMessage(
                    id: assistantID,
                    role: .assistant,
                    content: assistantText,
                    timestamp: assistantTS
                )

                // NEW: Feed TTS progressively
                if voiceEnabled {
                    ttsBuffer += token

                    // Conditions to enqueue a chunk early:
                    // 1) sentence boundary
                    // 2) newline
                    // 3) buffer is getting long (start speaking even before punctuation)
                    let hitSentenceEnd = ttsBuffer.contains(".") || ttsBuffer.contains("?") || ttsBuffer.contains("!")
                    let hitNewline = ttsBuffer.contains("\n")
                    let bufferLongEnough = ttsBuffer.count >= 80

                    // Avoid enqueuing constantly (must have grown since last enqueue)
                    let hasNewContent = assistantText.count - lastEnqueuedAtCount >= 25

                    if hasNewContent && (hitSentenceEnd || hitNewline || bufferLongEnough) {
                        // Enqueue the current buffer as a chunk and reset
                        SpeechManager.shared.enqueue(ttsBuffer)
                        lastEnqueuedAtCount = assistantText.count
                        ttsBuffer = ""
                    }
                }
            }

            // After streaming ends: speak whatever is left (if any)
            if voiceEnabled && !ttsBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SpeechManager.shared.enqueue(ttsBuffer)
            }

            conversations[convoIndex].updatedAt = Date()
            saveToDisk()
        } catch {
            conversations[convoIndex].messages.append(
                ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)")
            )
            conversations[convoIndex].updatedAt = Date()
            saveToDisk()
        }

        isGenerating = false
    }

    private func trimLLMHistory(_ llm: [LlamaChatMessage]) -> [LlamaChatMessage] {
        let maxMessages = 1 + (maxTurnsToKeep * 2)
        if llm.count <= maxMessages { return llm }
        let tail = llm.suffix(maxMessages - 1)
        return [llm[0]] + tail
    }

    private func autoTitleIfNeeded(convoIndex: Int, userText: String) {
        let userCount = conversations[convoIndex].messages.filter { $0.role == .user }.count
        if conversations[convoIndex].title == "New Chat" && userCount == 1 {
            let words = userText.split(separator: " ").prefix(5).map(String.init)
            if !words.isEmpty {
                conversations[convoIndex].title = words.joined(separator: " ")
            }
        }
    }

    private func loadFromDisk() {
        do {
            let data = try Data(contentsOf: saveURL)
            let decoded = try JSONDecoder().decode([Conversation].self, from: data)
            conversations = decoded.sorted(by: { $0.updatedAt > $1.updatedAt })
        } catch {
            conversations = []
        }
    }

    private func saveToDisk() {
        do {
            let sorted = conversations.sorted(by: { $0.updatedAt > $1.updatedAt })
            let data = try JSONEncoder().encode(sorted)
            try data.write(to: saveURL, options: [.atomic])
        } catch {
            // no-op
        }
    }
}
