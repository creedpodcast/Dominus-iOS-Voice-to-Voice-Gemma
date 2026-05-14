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
    /// Tracks the last user-turn index where each hidden ambient transcript cue
    /// was acknowledged, so the AI doesn't repeatedly comment on the same sound.
    var ambientCueLastAcknowledgedTurn: [String: Int]
    /// Hidden per-chat ambient history. These events are not shown as user
    /// messages, but they let Dominus answer direct recall questions like
    /// "what sound did I just make?"
    var ambientEvents: [AmbientEvent]
    /// Number of oldest messages already converted into short-term RAG summaries.
    var summarizedMessageCount: Int
    /// Rolling LLM-generated summary of messages that have aged out of the raw
    /// context window. Injected directly into every system prompt so older context
    /// is always available without burning raw-turn token budget.
    var rollingSummary: String

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = [],
        titleIsAuto: Bool = true,
        hasGeneratedTitle: Bool = false,
        ambientCueLastAcknowledgedTurn: [String: Int] = [:],
        ambientEvents: [AmbientEvent] = [],
        summarizedMessageCount: Int = 0,
        rollingSummary: String = ""
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.titleIsAuto = titleIsAuto
        self.hasGeneratedTitle = hasGeneratedTitle
        self.ambientCueLastAcknowledgedTurn = ambientCueLastAcknowledgedTurn
        self.ambientEvents = ambientEvents
        self.summarizedMessageCount = summarizedMessageCount
        self.rollingSummary = rollingSummary
    }

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, messages
        case titleIsAuto, hasGeneratedTitle
        case ambientCueLastAcknowledgedTurn
        case ambientEvents
        case summarizedMessageCount
        case rollingSummary
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
        ambientCueLastAcknowledgedTurn = try c.decodeIfPresent(
            [String: Int].self,
            forKey: .ambientCueLastAcknowledgedTurn
        ) ?? [:]
        ambientEvents = try c.decodeIfPresent([AmbientEvent].self, forKey: .ambientEvents) ?? []
        summarizedMessageCount = try c.decodeIfPresent(Int.self, forKey: .summarizedMessageCount) ?? 0
        rollingSummary = try c.decodeIfPresent(String.self, forKey: .rollingSummary) ?? ""
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

struct AmbientEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let key: String
    let label: String
    let timestamp: Date
    let userTurn: Int
    let duration: TimeInterval?

    init(
        id: UUID = UUID(),
        key: String,
        label: String,
        timestamp: Date = Date(),
        userTurn: Int,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.key = key
        self.label = label
        self.timestamp = timestamp
        self.userTurn = userTurn
        self.duration = duration
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
            updateEpisodeSummary(for: old)
            scheduleTitleGeneration(for: old)
        }
    }
    @Published var isGenerating: Bool = false
    @Published var isLoaded: Bool = false
    @Published var isLoading: Bool = false
    @Published var loadStatus: String = "Idle"
    @Published var loadProgress: Double = 0.0
    /// Bumps when voice mode captured only hidden ambient cues and chose not to
    /// generate a reply, so the UI can keep the PTT loop moving.
    @Published var silentAmbientEventCount: Int = 0

    /// Master TTS toggle. Used in BOTH text mode (header speaker icon) and
    /// voice mode (orb mute button). When entering PTT we force this true and
    /// restore the prior value on exit. Persisted across launches in UserDefaults.
    @Published var voiceEnabled: Bool = UserDefaults.standard.bool(forKey: "voiceEnabled") {
        didSet {
            UserDefaults.standard.set(voiceEnabled, forKey: "voiceEnabled")
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
    /// One-slot cache for speculative RAG retrieval kicked off while the user types.
    /// Consumed and cleared in `_send()` when the query matches exactly.
    private var cachedSpeculativeMemory: (query: String, context: String)?
    private var conversationMaintenanceTask: Task<Void, Never>?
    /// Background memory refinement also uses the single LlamaService instance, so chat wins.
    private var memoryRefinementTask: Task<Void, Never>?
    private var pendingMemoryRefinements: [MemoryRecord] = []
    private var isMemoryRefining = false
    private let maxMemorySummaryChars = 900

    private let engine = GemmaEngine()

    /// Passthrough for one-time inference warmup at launch. Hides the engine
    /// itself while letting ContentView gate the loading screen on warmup.
    func prewarmEngine() async { await engine.prewarm() }

    // MARK: - Context inspector snapshot

    /// A read-only snapshot of the last assembled LLM context, captured every
    /// turn. Used by the tappable context ring inspector sheet in ContentView.
    struct ContextSnapshot {
        struct Turn: Identifiable {
            let id = UUID()
            let role: String
            let content: String
            var tokens: Int { max(1, content.count / 4) }
        }
        var systemPrompt: String = ""
        var profile: String      = ""
        var memory: String       = ""
        var turns: [Turn]        = []

        var systemTokens: Int { max(1, systemPrompt.count / 4) }
        var profileTokens: Int  { max(1, profile.count / 4) }
        var memoryTokens: Int   { max(1, memory.count / 4) }
        var turnsTokens: Int    { turns.reduce(0) { $0 + $1.tokens } }
        var totalTokens: Int    { systemTokens + profileTokens + memoryTokens + turnsTokens }
    }

    @Published var lastContextSnapshot: ContextSnapshot = ContextSnapshot()

    /// Core identity — kept intentionally short to conserve token budget.
    private let systemPrompt = "You are Dominus, a direct and human AI assistant. Answer the user's latest message — nothing more. If you don't know something or weren't told it, say so plainly; do not guess or invent details. Match your length to the question: short questions get short answers, long questions get longer ones. No greetings, no preambles, no filler openers like \"Sure\" or \"Of course.\" Profile facts describe the user across chats; retrieved memory is current-chat only — use either only when it directly helps, otherwise ignore."
    
    /// Keep only the latest few raw turns in the prompt.
    /// Older current-chat context is covered by conversation RAG summaries/exchanges.
    private let maxTurnsToKeep = 4
    private let minTurnsToKeep = 3
    private let targetContextUsage: Double = 0.45
    private let approximateContextTokenLimit = 2048

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

    func contextUsageEstimate(for conversation: Conversation?, draft: String = "") -> Double {
        guard let conversation else {
            return targetContextUsage
        }

        var messages: [LlamaChatMessage] = [
            .init(role: .system, content: systemPrompt)
        ]
        messages += conversation.messages.compactMap { message in
            guard !isMemoryStatusMessage(message.content) else { return nil }
            switch message.role {
            case .user:
                return .init(role: .user, content: message.content)
            case .assistant:
                return .init(role: .assistant, content: message.content)
            }
        }

        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDraft.isEmpty {
            messages.append(.init(role: .user, content: trimmedDraft))
        }

        let trimmed = trimLLMHistory(messages)
        let usage = Double(estimatedTokens(for: trimmed)) / Double(approximateContextTokenLimit)
        return min(1.0, max(0.0, usage))
    }

    private func activeConversationMemoryContext(in conversation: Conversation, maxMessages: Int = 6) -> String {
        conversation.messages
            .filter { !isMemoryStatusMessage($0.content) }
            .suffix(maxMessages)
            .compactMap { message in
                let roleLabel: String
                switch message.role {
                case .user:
                    roleLabel = "User"
                case .assistant:
                    roleLabel = "Assistant"
                }
                let trimmed = message.content
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return "\(roleLabel): \(String(trimmed.prefix(240)))"
            }
            .joined(separator: "\n")
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
        MemoryRetriever.shared.deleteConversationMemory(conversationID: convo.id)
        MemoryStore.shared.delete(scope: .longTerm, sourceID: episodeSourceID(for: convo.id))
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
    /// Also clears any pending or playing TTS — when the user hits stop they expect
    /// silence, not for the AI to keep speaking the already-buffered sentences.
    func stopGeneration() {
        generationTask?.cancel()
        ThinkingFillerManager.shared.cancelScheduling()
        SpeechManager.shared.stopAndClear()
    }

    /// Non-async entry point — cancels any in-progress generation instantly, then starts fresh.
    /// Pre-fetch RAG memories while the user is composing a message so `_send()`
    /// can skip retrieval entirely on a cache hit. Called from ContentView with a
    /// 300 ms debounce on every keystroke. No-op when the model is busy.
    func speculativeRetrieve(for query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }
        guard let convoIndex = indexForSelectedConversation() else { return }
        guard shouldUseCurrentChatRecall(for: trimmed) else {
            cachedSpeculativeMemory = nil
            return
        }
        let convoID            = conversations[convoIndex].id
        let recentAssistantTxt = conversations[convoIndex].messages.reversed()
            .first(where: { $0.role == .assistant && !isMemoryStatusMessage($0.content) })?
            .content
        let profileBlock       = ProfileStore.shared.systemPromptBlock()
        let activeChatCtx      = activeConversationMemoryContext(in: conversations[convoIndex])

        let context = MemoryRetriever.shared.retrieve(
            query: trimmed,
            conversationID: convoID,
            recentAssistantText: recentAssistantTxt,
            profileContext: profileBlock,
            activeConversationContext: activeChatCtx,
            topK: 5
        )
        cachedSpeculativeMemory = (query: trimmed, context: context)
    }

    func send(
        _ userText: String,
        includeAmbientCues: Bool = false,
        ambientDuration: TimeInterval? = nil
    ) {
        // Title generation rides on the same LlamaService — cancel it first and await its
        // unwind so the new chat stream doesn't collide with an in-flight title stream.
        titleTask?.cancel()
        memoryRefinementTask?.cancel()
        conversationMaintenanceTask?.cancel()
        generationTask?.cancel()
        let prevTitle = titleTask
        let prevMemoryRefinement = memoryRefinementTask
        let prevMaintenance = conversationMaintenanceTask
        let prevGen = generationTask
        generationTask = Task { @MainActor [weak self] in
            await prevTitle?.value
            await prevMemoryRefinement?.value
            await prevMaintenance?.value
            await prevGen?.value
            await self?._send(
                userText,
                includeAmbientCues: includeAmbientCues,
                ambientDuration: ambientDuration
            )
        }
    }

    private func _send(
        _ userText: String,
        includeAmbientCues: Bool,
        ambientDuration: TimeInterval?
    ) async {
        loadModelIfNeeded()
        guard isLoaded else { return }
        guard let convoIndex = indexForSelectedConversation() else { return }

        let ambientResult = includeAmbientCues
            ? extractAmbientCues(from: userText)
            : (visibleText: userText, cues: [])
        let trimmed = ambientResult.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !ambientResult.cues.isEmpty else { return }

        let hasVisibleUserText = !trimmed.isEmpty
        let visibleUserText = trimmed
        let currentUserTurn = conversations[convoIndex].messages.filter { $0.role == .user }.count
        let nextUserTurn = currentUserTurn + 1
        let eligibleAmbientCues = ambientResult.cues.filter {
            shouldAcknowledgeAmbientCue($0, in: conversations[convoIndex], userTurn: nextUserTurn)
        }
        let shouldRespondToAmbientOnly = !hasVisibleUserText && shouldAutoRespondToAmbientOnly(
            cues: eligibleAmbientCues,
            duration: ambientDuration
        )

        recordAmbientEvents(
            ambientResult.cues,
            in: convoIndex,
            userTurn: nextUserTurn,
            duration: ambientDuration
        )

        guard hasVisibleUserText || shouldRespondToAmbientOnly else {
            conversations[convoIndex].updatedAt = Date()
            saveToDisk()
            silentAmbientEventCount += 1
            return
        }

        if hasVisibleUserText {
            conversations[convoIndex].messages.append(ChatMessage(role: .user, content: visibleUserText))
        }
        conversations[convoIndex].updatedAt = Date()
        if hasVisibleUserText {
            autoTitleIfNeeded(convoIndex: convoIndex, userText: visibleUserText)
        }
        saveToDisk()

        if hasVisibleUserText,
           let undoContent = memoryUndoContent(from: visibleUserText, in: conversations[convoIndex]) {
            MemoryStore.shared.deleteMatching(content: undoContent)
            appendMemoryStatus("Forgot Memory:\n\(undoContent)", convoIndex: convoIndex, speak: voiceEnabled)
            isGenerating = false
            return
        }

        isGenerating = true

        // ── Build LLM context ──────────────────────────────────────────────
        // 1. User profile — always injected first
        let profileBlock = ProfileStore.shared.systemPromptBlock()

        // 2. Retrieve older current-chat context only when the latest message asks for recall.
        let recentAssistantText = conversations[convoIndex].messages.reversed()
            .first(where: { $0.role == .assistant && !isMemoryStatusMessage($0.content) })?
            .content
        let activeConversationContext = activeConversationMemoryContext(in: conversations[convoIndex])
        let shouldRetrieveCurrentChat = hasVisibleUserText && shouldUseCurrentChatRecall(for: visibleUserText)
        // Use speculative retrieval result if the query matches exactly; otherwise
        // fall back to a fresh retrieve call. Cache is cleared after each send.
        let memoryContext: String
        if shouldRetrieveCurrentChat,
           let cached = cachedSpeculativeMemory,
           cached.query == visibleUserText {
            memoryContext = cached.context
            cachedSpeculativeMemory = nil
        } else if shouldRetrieveCurrentChat {
            memoryContext = MemoryRetriever.shared.retrieve(
                query: visibleUserText,
                conversationID: conversations[convoIndex].id,
                recentAssistantText: recentAssistantText,
                profileContext: profileBlock,
                activeConversationContext: activeConversationContext,
                topK: 5
            )
            cachedSpeculativeMemory = nil
        } else {
            memoryContext = ""
            cachedSpeculativeMemory = nil
        }

        // 3. Compose full system prompt
        var fullSystemPrompt = systemPrompt
        if !profileBlock.isEmpty {
            fullSystemPrompt += "\n\n\(profileBlock)"
        }
        // Rolling summary — older turns compressed by the LLM and injected directly
        // so prior context is always available without spending raw-turn token budget.
        let rollingSummary = conversations[convoIndex].rollingSummary
        if !rollingSummary.isEmpty {
            fullSystemPrompt += "\n\nEarlier in this conversation:\n\(rollingSummary)"
        }
        if !memoryContext.isEmpty {
            fullSystemPrompt += "\n\n\(memoryContext)"
        }
        let recentAmbientContext = recentAmbientEventsPromptBlock(for: conversations[convoIndex])
        if !recentAmbientContext.isEmpty {
            fullSystemPrompt += "\n\n\(recentAmbientContext)"
        }
        if !eligibleAmbientCues.isEmpty {
            let activeAmbientBlock = ambientCuePromptBlock(
                for: eligibleAmbientCues,
                ambientOnly: !hasVisibleUserText
            )
            fullSystemPrompt += "\n\n\(activeAmbientBlock)"
        }

        // 3. Build message list: system + last N turns of raw history
        var llmMessages: [LlamaChatMessage] = [
            .init(role: .system, content: fullSystemPrompt)
        ]
        llmMessages += conversations[convoIndex].messages.compactMap { m in
            guard !isMemoryStatusMessage(m.content) else { return nil }
            switch m.role {
            case .user:      return .init(role: .user,      content: m.content)
            case .assistant: return .init(role: .assistant, content: m.content)
            }
        }
        if !hasVisibleUserText {
            llmMessages.append(.init(
                role: .user,
                content: ambientOnlyUserPrompt(for: eligibleAmbientCues, duration: ambientDuration)
            ))
        }
        llmMessages = filterNoiseTurns(llmMessages)
        llmMessages = trimLLMHistory(llmMessages)

        // Snapshot the assembled context for the inspector sheet (tappable ring).
        lastContextSnapshot = ContextSnapshot(
            systemPrompt: systemPrompt,
            profile:      profileBlock,
            memory:       memoryContext,
            turns:        llmMessages.dropFirst().map {
                ContextSnapshot.Turn(role: $0.role == .user ? "You" : "Dominus",
                                     content: $0.content)
            }
        )

        let shouldUseThinkingFiller = voiceEnabled && includeAmbientCues
        if voiceEnabled {
            SpeechManager.shared.stopAndClear()
        }
        if shouldUseThinkingFiller {
            ThinkingFillerManager.shared.start(
                for: hasVisibleUserText
                    ? visibleUserText
                    : ambientOnlyUserPrompt(for: eligibleAmbientCues, duration: ambientDuration),
                recentAssistantText: recentAssistantText,
                personality: .curious
            )
        }

        do {
            let placeholder = ChatMessage(role: .assistant, content: "Thinking...")
            conversations[convoIndex].messages.append(placeholder)

            let assistantIndex = conversations[convoIndex].messages.count - 1
            let assistantID    = conversations[convoIndex].messages[assistantIndex].id
            let assistantTS    = conversations[convoIndex].messages[assistantIndex].timestamp

            let stream = try await engine.streamChat(llmMessages, temperature: 0.7, seed: 42)

            // Length-match the response to the question. Soft cap that only kicks
            // in at a sentence boundary, so we never chop a sentence mid-word.
            let responseCharCap: Int? = {
                let wordCount = visibleUserText
                    .split(whereSeparator: { $0.isWhitespace })
                    .count
                switch wordCount {
                case 0...5:   return 200
                case 6...15:  return 500
                case 16...40: return 1200
                default:      return nil
                }
            }()

            var assistantText = ""
            var ttsBuffer     = ""
            var lastEnqueuedAtCount = 0
            var realSpeechHasStarted = false
            // Batch SwiftUI re-renders: push a new ChatMessage every N tokens instead
            // of every single one. TTS sentence detection still runs per-token.
            // At ~20 tok/s this gives ~3 UI updates/s — smooth to the eye, and the
            // main thread stays free for typing, scrolling, and button taps.
            // Exception: the very first token always flushes immediately so the
            // response feels instant.
            var uiTokenCount = 0
            let uiTokenBatch = 6
            var hasShownFirstToken = false
            let generationStartedAt = Date()

            for try await token in stream {
                // Exit immediately if a new message was sent
                try Task.checkCancellation()

                assistantText += token
                uiTokenCount  += 1

                if !hasShownFirstToken {
                    hasShownFirstToken = true
                    // B: if the first token arrives quickly the thinking filler hasn't
                    // finished yet — cancel it before it starts talking over the answer.
                    let ttft = Date().timeIntervalSince(generationStartedAt)
                    if ttft < 1.5 {
                        ThinkingFillerManager.shared.cancelScheduling()
                    }
                    // A: always show the first token immediately so the response
                    // feels instant rather than waiting for a full batch to accumulate.
                    let displayText = stripRoboticOpener(cleanLlamaArtifacts(assistantText))
                    conversations[convoIndex].messages[assistantIndex] = ChatMessage(
                        id: assistantID,
                        role: .assistant,
                        content: displayText,
                        timestamp: assistantTS
                    )
                    uiTokenCount = 0
                } else if uiTokenCount >= uiTokenBatch {
                    let displayText = stripRoboticOpener(cleanLlamaArtifacts(assistantText))
                    conversations[convoIndex].messages[assistantIndex] = ChatMessage(
                        id: assistantID,
                        role: .assistant,
                        content: displayText,
                        timestamp: assistantTS
                    )
                    uiTokenCount = 0
                }

                if voiceEnabled {
                    ttsBuffer += token
                    let trimmedTTSBuffer = ttsBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    let hitSentenceEnd   = trimmedTTSBuffer.last == "." || trimmedTTSBuffer.last == "?" || trimmedTTSBuffer.last == "!"
                    let hitNewline       = ttsBuffer.contains("\n")
                    let bufferTooLong    = ttsBuffer.count >= 300

                    // Fire on complete sentences immediately — no minimum length guard.
                    // 300-char ceiling only cuts truly runaway sentences.
                    if hitSentenceEnd || hitNewline || bufferTooLong {
                        if !realSpeechHasStarted {
                            ThinkingFillerManager.shared.prepareForRealAnswer()
                            realSpeechHasStarted = true
                            // Strip robotic openers from the very first TTS chunk so
                            // "Sure! Here's what I found." is spoken as "Here's what I found."
                            ttsBuffer = stripRoboticOpener(ttsBuffer)
                        }
                        SpeechManager.shared.enqueue(ttsBuffer)
                        lastEnqueuedAtCount = assistantText.count
                        ttsBuffer = ""
                    }
                }

                if let cap = responseCharCap, assistantText.count >= cap {
                    let trimmed = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let last = trimmed.last, last == "." || last == "?" || last == "!" || last == "\n" {
                        break
                    }
                }
            }

            // Final UI flush — always write the complete text so the last
            // few tokens (which may not have hit the batch boundary) are shown.
            let finalDisplayText = stripRoboticOpener(cleanLlamaArtifacts(assistantText))
            conversations[convoIndex].messages[assistantIndex] = ChatMessage(
                id: assistantID,
                role: .assistant,
                content: finalDisplayText,
                timestamp: assistantTS
            )

            if voiceEnabled && !ttsBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !realSpeechHasStarted {
                    ThinkingFillerManager.shared.prepareForRealAnswer()
                    realSpeechHasStarted = true
                }
                SpeechManager.shared.enqueue(ttsBuffer)
            }
            ThinkingFillerManager.shared.prepareForRealAnswer()

            for cue in eligibleAmbientCues {
                conversations[convoIndex].ambientCueLastAcknowledgedTurn[cue.key] = nextUserTurn
            }
            conversations[convoIndex].updatedAt = Date()
            saveToDisk()

            // ── Store exchange in conversation memory (fire-and-forget) ───
            let cleanedAssistant = conversations[convoIndex].messages[assistantIndex].content
            if !cleanedAssistant.isEmpty {
                if hasVisibleUserText {
                    MemoryRetriever.shared.remember(
                        conversationID: conversations[convoIndex].id,
                        userText: visibleUserText,
                        assistantText: cleanedAssistant
                    )
                    scheduleConversationMaintenance(for: conversations[convoIndex].id)
                }
            }

            // ── Schedule LLM title generation after the 8th user turn ──
            // Earlier turns rely on the exit triggers (chat-switch, app-background)
            // to produce a title for short-lived chats.
            let userTurns = conversations[convoIndex].messages.filter { $0.role == .user }.count
            if hasVisibleUserText && userTurns >= 8 {
                scheduleTitleGeneration(for: conversations[convoIndex].id)
            }

        } catch {
            // SwiftLlama throws LlamaError instead of CancellationError when the task
            // is cancelled mid-stream — check Task.isCancelled to handle both cases
            if Task.isCancelled || error is CancellationError {
                // User interrupted — keep partial response, remove empty placeholder
                if let idx = conversations[convoIndex].messages.indices.last,
                   conversations[convoIndex].messages[idx].content.isEmpty ||
                    conversations[convoIndex].messages[idx].content == "Thinking..." {
                    conversations[convoIndex].messages.removeLast()
                }
                SpeechManager.shared.stopAndClear()
            } else {
                if let idx = conversations[convoIndex].messages.indices.last,
                   conversations[convoIndex].messages[idx].content.isEmpty ||
                    conversations[convoIndex].messages[idx].content == "Thinking..." {
                    conversations[convoIndex].messages.removeLast()
                }
                SpeechManager.shared.stopAndClear()
                print("❌ Llama generation error:", error.localizedDescription)
            }
            ThinkingFillerManager.shared.cancelScheduling()
            conversations[convoIndex].updatedAt = Date()
            saveToDisk()
        }

        isGenerating = false
        startMemoryRefinementWorkerIfNeeded()
    }

    // MARK: - Helpers

    private struct AmbientCue: Equatable {
        let key: String
        let label: String
    }

    private let ambientCueCooldownTurns = 12
    private let maxStoredAmbientEvents = 24

    /// Whisper can return non-speech markers such as "[Laughter]", "(coughing)",
    /// or "(keyboard typing)". Keep them out of the visible transcript, but let
    /// the model react privately when the per-chat cooldown allows it.
    private func extractAmbientCues(from text: String) -> (visibleText: String, cues: [AmbientCue]) {
        let pattern = "(?:\\[([^\\]\\n]{1,48})\\]|\\(([^)\\n]{1,48})\\))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, [])
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return (text, []) }

        var visibleText = text
        var cues: [AmbientCue] = []
        var seenKeys = Set<String>()

        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let bracketRange = match.range(at: 1)
            let parenRange = match.numberOfRanges > 2 ? match.range(at: 2) : NSRange(location: NSNotFound, length: 0)
            let labelRange = bracketRange.location != NSNotFound ? bracketRange : parenRange
            guard labelRange.location != NSNotFound else { continue }
            let rawLabel = nsText.substring(with: labelRange)
            guard let cue = normalizeAmbientCue(rawLabel), !seenKeys.contains(cue.key) else {
                continue
            }
            seenKeys.insert(cue.key)
            cues.append(cue)
        }

        for match in matches.reversed() {
            if let range = Range(match.range, in: visibleText) {
                visibleText.removeSubrange(range)
            }
        }

        visibleText = visibleText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (visibleText, cues)
    }

    private func normalizeAmbientCue(_ rawLabel: String) -> AmbientCue? {
        let trimmed = rawLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".:,;!?-_"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        guard !trimmed.isEmpty else { return nil }

        let key = trimmed.lowercased()
        let label = trimmed.prefix(1).uppercased() + trimmed.dropFirst().lowercased()
        return AmbientCue(key: key, label: String(label))
    }

    private func shouldAcknowledgeAmbientCue(
        _ cue: AmbientCue,
        in conversation: Conversation,
        userTurn: Int
    ) -> Bool {
        guard let lastTurn = conversation.ambientCueLastAcknowledgedTurn[cue.key] else {
            return true
        }
        return userTurn - lastTurn >= ambientCueCooldownTurns
    }

    private func shouldAutoRespondToAmbientOnly(cues: [AmbientCue], duration: TimeInterval?) -> Bool {
        guard !cues.isEmpty else { return false }

        if cues.contains(where: { $0.key.contains("silence") }) {
            return (duration ?? 0) >= 60
        }

        let highestChance = cues.map { ambientOnlyResponseChance(for: $0) }.max() ?? 0
        guard highestChance > 0 else { return false }
        return Double.random(in: 0...1) < highestChance
    }

    private func ambientOnlyResponseChance(for cue: AmbientCue) -> Double {
        if cue.key.contains("laughter") || cue.key.contains("laughing") {
            return 0.45
        }
        if cue.key.contains("cough") || cue.key.contains("sneez") {
            return 0.25
        }
        if cue.key.contains("typing") || cue.key.contains("keyboard") {
            return 0.08
        }
        return 0.12
    }

    private func recordAmbientEvents(
        _ cues: [AmbientCue],
        in convoIndex: Int,
        userTurn: Int,
        duration: TimeInterval?
    ) {
        guard !cues.isEmpty, conversations.indices.contains(convoIndex) else { return }

        let newEvents = cues.map {
            AmbientEvent(
                key: $0.key,
                label: $0.label,
                userTurn: userTurn,
                duration: duration
            )
        }

        conversations[convoIndex].ambientEvents.append(contentsOf: newEvents)
        if conversations[convoIndex].ambientEvents.count > maxStoredAmbientEvents {
            conversations[convoIndex].ambientEvents = Array(
                conversations[convoIndex].ambientEvents.suffix(maxStoredAmbientEvents)
            )
        }
    }

    private func recentAmbientEventsPromptBlock(for conversation: Conversation) -> String {
        let recent = conversation.ambientEvents.suffix(8)
        guard !recent.isEmpty else { return "" }

        let lines = recent.map { event in
            let durationText = event.duration.map { String(format: ", recording %.0fs", $0) } ?? ""
            return "- \(event.label) near user turn \(event.userTurn)\(durationText)"
        }.joined(separator: "\n")

        return """
        Hidden recent ambient events:
        \(lines)
        These are not visible chat messages. Use them only if the user asks what you heard, what sound they made, what they were just doing, or if a separate active ambient instruction says to mention one. Otherwise do not bring them up.
        """
    }

    private func ambientCuePromptBlock(for cues: [AmbientCue], ambientOnly: Bool) -> String {
        let labels = cues.map(\.label).joined(separator: ", ")
        if ambientOnly {
            return """
            Active hidden ambient context: the user did not speak words, but the transcript detected: \(labels).
            If you respond, keep it brief and human. Do not quote the bracket syntax. Do not overreact. Do not repeatedly mention the same cue.
            """
        }

        return """
        Hidden ambient context: the voice transcript contained these non-speech background cues, removed from the visible user message: \(labels).
        Briefly acknowledge this ambient context once in your reply if it feels natural. Do not quote the bracket syntax. Do not mention the same cue again until it reappears much later in the chat.
        """
    }

    private func ambientOnlyUserPrompt(for cues: [AmbientCue], duration: TimeInterval?) -> String {
        let labels = cues.map(\.label).joined(separator: ", ")
        if cues.contains(where: { $0.key.contains("silence") }), (duration ?? 0) >= 60 {
            return "The user has been silent for about one minute while voice mode appears to still be active. Check in briefly."
        }
        return "The user did not speak words. Hidden ambient sound detected: \(labels). Respond only if it feels natural."
    }

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

    /// Strip filler openers ("Sure!", "Certainly,", "Of course!" etc.) from the very
    /// start of a response. Only fires when the opener is followed by more content so
    /// a one-word acknowledgement ("Sure.") that IS the full answer is left intact.
    private func stripRoboticOpener(_ text: String) -> String {
        let pattern = #"^(?i)(Sure|Certainly|Of course|Absolutely|Definitely|No problem|Great)[!,.]?\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, range: range) {
            let matchRange = Range(match.range, in: text)!
            let remainder = String(text[matchRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Only strip if there's still a real response left after the opener.
            return remainder.isEmpty ? text : remainder
        }
        return text
    }

    /// Keep system message + recent raw turns. If the prompt estimate still rises
    /// past the 45% target, drop older raw turns down to the minimum recent window.
    private func trimLLMHistory(_ llm: [LlamaChatMessage]) -> [LlamaChatMessage] {
        let maxMessages = 1 + (maxTurnsToKeep * 2)
        let minMessages = 1 + (minTurnsToKeep * 2)

        var trimmed = llm.count <= maxMessages
            ? llm
            : [llm[0]] + Array(llm.suffix(maxMessages - 1))

        while trimmed.count > minMessages,
              estimatedTokens(for: trimmed) > Int(Double(approximateContextTokenLimit) * targetContextUsage) {
            trimmed.remove(at: 1)
        }

        return trimmed
    }

    /// Drop low-signal user turns ("ok", "yeah", "thanks" etc.) and their paired
    /// assistant responses from the LLM history before it's sent to the model.
    /// Never drops the most recent 2 full turns — recency always wins.
    /// The chat UI is unaffected; this only filters what the model sees.
    private func filterNoiseTurns(_ llm: [LlamaChatMessage]) -> [LlamaChatMessage] {
        guard llm.count > 1 else { return llm }
        let system = llm[0]
        var turns = Array(llm.dropFirst())

        // Always preserve the last 4 messages (2 full user+assistant pairs).
        let alwaysKeep = min(4, turns.count)
        let candidateCount = turns.count - alwaysKeep
        guard candidateCount > 0 else { return llm }

        var result: [LlamaChatMessage] = []
        var i = 0
        while i < candidateCount {
            let msg = turns[i]
            if msg.role == .user, isNoiseTurn(msg.content) {
                i += 1 // skip user noise turn
                if i < candidateCount, turns[i].role == .assistant {
                    i += 1 // skip the paired assistant response too
                }
            } else {
                result.append(msg)
                i += 1
            }
        }
        result += turns.suffix(alwaysKeep)
        return [system] + result
    }

    /// Returns true when the user turn is pure conversational filler with no
    /// substantive content for the model to reason about.
    private func isNoiseTurn(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let noiseSet: Set<String> = [
            "ok", "okay", "k", "yeah", "yep", "yup", "nope",
            "thanks", "thank you", "thx", "ty",
            "cool", "nice", "great", "got it", "got it thanks",
            "sure", "right", "alright", "sounds good",
            "hm", "hmm", "lol", "haha",
            "ok thanks", "okay thanks", "yeah thanks",
        ]
        return noiseSet.contains(normalized)
    }

    private func estimatedTokens(for messages: [LlamaChatMessage]) -> Int {
        let chars = messages.reduce(0) { $0 + $1.content.count }
        return max(1, chars / 4)
    }

    /// Persist compact summaries for messages that are about to live outside the raw prompt window.
    /// This avoids unbounded context growth while still letting RAG recover older conversation details.
    private func summarizeOlderMessagesIfNeeded(convoIndex: Int) {
        guard conversations.indices.contains(convoIndex) else { return }

        let rawHistoryLimit = maxTurnsToKeep * 2
        let messages = conversations[convoIndex].messages
        let cutoff = max(0, messages.count - rawHistoryLimit)
        let alreadySummarized = min(conversations[convoIndex].summarizedMessageCount, messages.count)

        // Wait until at least two full turns have aged out before creating a summary chunk.
        guard cutoff - alreadySummarized >= 4 else { return }

        let slice = Array(messages[alreadySummarized..<cutoff])
        let convoID = conversations[convoIndex].id
        let sourceID = "\(alreadySummarized)-\(cutoff)"

        Task { @MainActor [weak self] in
            guard let self, !self.isGenerating else { return }
            guard let newSummary = await self.generateRollingSummary(for: slice) else { return }
            guard let idx = self.conversations.firstIndex(where: { $0.id == convoID }) else { return }

            // Append-only: layer new summary onto existing one so older context
            // is preserved without reprocessing the full history.
            let existing = self.conversations[idx].rollingSummary
            self.conversations[idx].rollingSummary = existing.isEmpty
                ? newSummary
                : "\(existing)\n\(newSummary)"
            self.conversations[idx].summarizedMessageCount = cutoff

            // Also store in RAG so retrieval can surface it when relevant.
            MemoryRetriever.shared.rememberSummary(
                conversationID: convoID,
                summary: newSummary,
                sourceID: sourceID
            )
            self.saveToDisk()
        }
    }

    /// Ask the model to produce a concise 2-3 sentence summary of a message slice.
    /// Runs as a side-channel generation — never blocks the main chat path.
    private func generateRollingSummary(for messages: [ChatMessage]) async -> String? {
        guard !messages.isEmpty else { return nil }

        let transcript = messages
            .filter { !isMemoryStatusMessage($0.content) }
            .map { m in
                let label = m.role == .user ? "User" : "Dominus"
                let text = m.content
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let capped = text.count > 300
                    ? String(text.prefix(300)) + "..."
                    : text
                return "\(label): \(capped)"
            }
            .joined(separator: "\n")

        guard !transcript.isEmpty else { return nil }

        let prompt: [LlamaChatMessage] = [
            .init(role: .system, content: "You write concise conversation summaries. Output 2-3 plain sentences only. No preamble, no bullet points, no headers. Focus on what the user said and what was decided or explained."),
            .init(role: .user, content: "Summarize this conversation excerpt:\n\n\(transcript)")
        ]

        do {
            let raw = try await engine.generateOnce(prompt, temperature: 0.3, maxChars: 400)
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            print("⚠️ Rolling summary generation failed:", error.localizedDescription)
            return nil
        }
    }

    private func scheduleConversationMaintenance(for conversationID: UUID) {
        conversationMaintenanceTask?.cancel()
        conversationMaintenanceTask = Task { @MainActor [weak self] in
            defer { self?.conversationMaintenanceTask = nil }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            guard !self.isGenerating, !self.isMemoryRefining else { return }
            guard let index = self.conversations.firstIndex(where: { $0.id == conversationID }) else { return }
            self.summarizeOlderMessagesIfNeeded(convoIndex: index)
            self.updateEpisodeSummary(convoIndex: index)
        }
    }

    private func compactSummary(for messages: [ChatMessage]) -> String {
        messages.map { message in
            guard message.role == .user else { return "" }
            guard !isMemoryStatusMessage(message.content) else { return "" }
            let oneLine = message.content
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !oneLine.isEmpty else { return "" }
            let capped = oneLine.count > 220
                ? String(oneLine.prefix(220)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
                : oneLine
            return "User: \(capped)"
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    func updateCurrentEpisodeSummary() {
        guard let selectedID else { return }
        updateEpisodeSummary(for: selectedID)
    }

    private func updateEpisodeSummary(for conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        updateEpisodeSummary(convoIndex: index)
    }

    private func updateEpisodeSummary(convoIndex: Int) {
        guard conversations.indices.contains(convoIndex) else { return }
        let conversation = conversations[convoIndex]
        let summary = episodeSummary(for: conversation)
        guard !summary.isEmpty else { return }
        MemoryRetriever.shared.rememberEpisodeSummary(
            conversationID: conversation.id,
            summary: summary
        )
    }

    private func episodeSourceID(for conversationID: UUID) -> String {
        "episode:\(conversationID.uuidString)"
    }

    private func episodeSummary(for conversation: Conversation) -> String {
        let visibleMessages = conversation.messages
            .filter { !isMemoryStatusMessage($0.content) }
        let userMessages = visibleMessages.filter { $0.role == .user }
        guard userMessages.count >= 2 else { return "" }

        let title = conversation.title == "New Chat" ? "Untitled chat" : conversation.title
        let topics = episodeKeywords(from: userMessages.map(\.content).joined(separator: " "))
            .prefix(8)
            .joined(separator: ", ")
        let recentExchange = visibleMessages.suffix(8).map { message in
            let label = message.role == .user ? "Creed" : "Dominus"
            let clean = message.content
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let capped = clean.count > 180
                ? String(clean.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
                : clean
            return "\(label): \(capped)"
        }.joined(separator: " | ")

        let decisionLines = userMessages
            .map(\.content)
            .filter { text in
                let lower = text.lowercased()
                return lower.contains("let's")
                    || lower.contains("we should")
                    || lower.contains("i want")
                    || lower.contains("i think")
                    || lower.contains("next")
                    || lower.contains("works")
            }
            .suffix(4)
            .map { text in
                text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .joined(separator: " ")

        var parts = [
            "Conversation episode from \"\(title)\".",
            "Creed and Dominus discussed \(topics.isEmpty ? "the active project and decisions in this chat" : topics).",
            "Recent context: \(recentExchange)"
        ]
        if !decisionLines.isEmpty {
            parts.append("Notable decisions or direction from Creed: \(decisionLines)")
        }
        return parts.joined(separator: " ")
    }

    private func episodeKeywords(from text: String) -> [String] {
        let stopWords: Set<String> = [
            "the","and","that","this","with","from","have","what","when","where",
            "about","into","onto","then","there","their","would","could","should",
            "you","creed","dominus","memory","remember","because","thing","things"
        ]
        var seen = Set<String>()
        return text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count > 3 && !stopWords.contains($0) }
            .filter { seen.insert($0).inserted }
    }

    private func appendMemoryStatus(_ content: String, convoIndex: Int, speak: Bool) {
        conversations[convoIndex].messages.append(ChatMessage(role: .assistant, content: content))
        conversations[convoIndex].updatedAt = Date()
        saveToDisk()

        if speak {
            SpeechManager.shared.enqueue(
                content
                    .replacingOccurrences(of: "Memory Suggestion:", with: "Memory suggestion.")
                    .replacingOccurrences(of: "Added to Memory:", with: "Added to memory.")
                    .replacingOccurrences(of: "Added to Memory", with: "Added to memory.")
                    .replacingOccurrences(of: "Forgot Memory:", with: "Forgot memory.")
            )
        }
    }

    private func isMemoryStatusMessage(_ text: String) -> Bool {
        text.hasPrefix("Added to Memory")
            || text.hasPrefix("Memory Suggestion:")
            || text.hasPrefix("Memory suggestion dismissed")
            || text.hasPrefix("Forgot Memory:")
    }

    private func memoryUndoContent(from text: String, in conversation: Conversation) -> String? {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "[^a-z\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let undoPhrases = [
            "never mind",
            "nevermind",
            "forget that",
            "forget it",
            "delete that memory",
            "remove that memory"
        ]
        guard undoPhrases.contains(where: { normalized == $0 || normalized.contains($0) }) else {
            return nil
        }

        for message in conversation.messages.reversed() {
            guard message.content.hasPrefix("Added to Memory") else { continue }
            let content = message.content
                .replacingOccurrences(of: "Added to Memory:", with: "")
                .replacingOccurrences(of: "Added to Memory", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                return content
            }
        }

        return nil
    }

    private func shouldUseCurrentChatRecall(for text: String) -> Bool {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s']", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let recallPhrases = [
            "earlier",
            "before",
            "previous",
            "previously",
            "last time",
            "a while ago",
            "what did i say",
            "what did we say",
            "what were we talking",
            "what was i saying",
            "what was the thing",
            "that idea",
            "that point",
            "that part",
            "the thing i said",
            "the thing we discussed",
            "continue from",
            "pick up where",
            "go back to",
            "recall",
            "remember when",
            "in this chat",
            "this conversation",
            "summarize this chat",
            "summarize our conversation"
        ]

        return recallPhrases.contains { normalized.contains($0) }
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

    func refineMemoryWithLLM(_ record: MemoryRecord) {
        scheduleMemoryRefinement(for: record)
    }

    func refineUnsummarizedMemoriesWithLLM() {
        MemoryStore.shared.fetch(scope: .longTerm)
            .filter { memoryNeedsRefinement($0) }
            .forEach { scheduleMemoryRefinement(for: $0) }
    }

    func generateMemoryEditSummary(_ draft: String) async -> String? {
        guard !isGenerating, !isMemoryRefining else { return nil }
        let cleanDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDraft.isEmpty else { return nil }
        loadModelIfNeeded()
        let modelReady = await waitForModelReady(timeoutSeconds: 8)
        guard modelReady else {
            return UserMemoryFormatter.memoryContent(from: cleanDraft)
        }

        let profileName = ProfileStore.shared.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let userName = profileName.isEmpty ? "the user" : profileName
        let summarySystem = """
        Rewrite a user-edited memory into 1 to 3 complete short memory sentences about \(userName).

        Rules:
        - Preserve only facts from the user's edit.
        - Write direct memory notes, such as "\(userName) said..." or "\(userName) prefers..."
        - Do not mention the assistant by name.
        - Do not add labels, bullets, quotes, or explanations.
        """

        isMemoryRefining = true
        defer { isMemoryRefining = false }

        do {
            let raw = try await engine.generateOnce(
                [
                    .init(role: .system, content: summarySystem),
                    .init(role: .user, content: "Edited memory:\n\(cleanDraft)"),
                ],
                temperature: 0.25,
                seed: 13,
                maxChars: maxMemorySummaryChars
            )
            return cleanMemoryRefinementResponse(raw)
        } catch {
            return nil
        }
    }

    private func waitForModelReady(timeoutSeconds: Double) async -> Bool {
        if isLoaded { return true }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isLoaded { return true }
            if !isLoading {
                loadModelIfNeeded()
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return isLoaded
    }

    private func scheduleMemoryRefinement(for record: MemoryRecord) {
        guard record.scope == .longTerm else { return }
        guard record.kind != .memoryCandidate else { return }
        guard !MemoryStore.shared.hasBeenRefinedOnce(record) else { return }
        pendingMemoryRefinements.append(record)
        startMemoryRefinementWorkerIfNeeded()
    }

    private func memoryNeedsRefinement(_ record: MemoryRecord) -> Bool {
        guard !MemoryStore.shared.hasBeenRefinedOnce(record) else { return false }
        let content = record.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return false }
        let lower = content.lowercased()
        return content.count > 180
            || content.contains("\n")
            || lower.contains("user:")
            || lower.contains("creed noted")
            || lower.hasPrefix("memory:")
            || lower.hasPrefix("summary:")
            || record.title != nil
    }

    private func startMemoryRefinementWorkerIfNeeded() {
        guard memoryRefinementTask == nil else { return }
        memoryRefinementTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)

            while !Task.isCancelled {
                guard let self else { return }
                if self.isGenerating
                    || self.isLoading
                    || self.isMemoryRefining
                    || SpeechManager.shared.isSpeaking
                    || SpeechRecognitionManager.shared.isListening {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                guard !self.pendingMemoryRefinements.isEmpty else { break }
                let record = self.pendingMemoryRefinements.removeFirst()
                await self._refineMemoryWithLLM(record)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            self?.memoryRefinementTask = nil
        }
    }

    private func _refineMemoryWithLLM(_ record: MemoryRecord) async {
        guard !isGenerating, !isMemoryRefining else { return }
        loadModelIfNeeded()
        guard isLoaded else {
            pendingMemoryRefinements.insert(record, at: 0)
            return
        }
        guard record.scope == .longTerm, record.kind != .memoryCandidate else { return }

        let memoryDescription = record.content
            .replacingOccurrences(of: #"(?m)^\s*[-•]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !memoryDescription.isEmpty else { return }

        let profileName = ProfileStore.shared.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let userName = profileName.isEmpty ? "the user" : profileName
        let memorySystem = """
        You clean up local AI memory requests. Output only a few short memory sentences about \(userName).

        Rules:
        - Base the summary only on the memory description.
        - Identify the main things \(userName) wanted remembered.
        - Write as direct memory notes, such as "\(userName) said..." or "\(userName) prefers..."
        - Do not describe the request itself or mention the assistant by name.
        - Use 1 to 3 complete short sentences.
        - Do not add facts that are not in the memory description.
        - Do not use labels like Title, Summary, User Fact, or Memory.
        - Do not mention these rules.
        """
        let memoryUser = """
        Memory description:
        \(memoryDescription)
        """

        isMemoryRefining = true
        defer { isMemoryRefining = false }

        do {
            try Task.checkCancellation()
            let raw = try await engine.generateOnce(
                [
                    .init(role: .system, content: memorySystem),
                    .init(role: .user, content: memoryUser),
                ],
                temperature: 0.25,
                seed: 11,
                maxChars: maxMemorySummaryChars
            )
            try Task.checkCancellation()
            guard let refined = cleanMemoryRefinementResponse(raw) else { return }
            MemoryStore.shared.update(
                record,
                kind: record.kind,
                title: nil,
                content: refined,
                categoryKey: record.categoryRaw
            )
            MemoryStore.shared.markRefinedOnce(record)
        } catch {
            // Chat and voice generation are higher priority; cancelled refinements can retry later.
        }
    }

    private func cleanMemoryRefinementResponse(_ raw: String) -> String? {
        var cleaned = cleanLlamaArtifacts(raw)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        var summary = cleaned
            .replacingOccurrences(of: #"(?i)^(title|summary|user fact|memory)\s*:\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*[-•]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers: Set<Character> = ["\"", "'", "`", "*"]
        while let first = summary.first, wrappers.contains(first) { summary.removeFirst() }
        while let last = summary.last, wrappers.contains(last) { summary.removeLast() }
        summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        summary = completeMemorySentences(from: summary, maxSentences: 3)
        return summary.isEmpty ? nil : summary
    }

    private func completeMemorySentences(from text: String, maxSentences: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let pattern = #"[^.!?]+[.!?]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return trimmed }
        let nsText = trimmed as NSString
        let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: nsText.length))

        let sentences = matches.prefix(maxSentences).compactMap { match -> String? in
            guard let range = Range(match.range, in: trimmed) else { return nil }
            return String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if !sentences.isEmpty {
            return sentences.joined(separator: " ")
        }

        return trimmed
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
        guard !isGenerating, !isMemoryRefining else { return }
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
