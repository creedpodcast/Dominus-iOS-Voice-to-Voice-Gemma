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

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = [],
        titleIsAuto: Bool = true,
        hasGeneratedTitle: Bool = false,
        ambientCueLastAcknowledgedTurn: [String: Int] = [:],
        ambientEvents: [AmbientEvent] = []
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
    }

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, messages
        case titleIsAuto, hasGeneratedTitle
        case ambientCueLastAcknowledgedTurn
        case ambientEvents
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

    private let engine = GemmaEngine()

    /// Core identity — kept intentionally short to conserve token budget.
    private let systemPrompt = "You are Dominus — a friendly but curious AI Assistant. Answer the user directly. Do not add unsolicited greetings, introductions, or preambles, even on the first turn of a new chat."
    
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
    /// Also clears any pending or playing TTS — when the user hits stop they expect
    /// silence, not for the AI to keep speaking the already-buffered sentences.
    func stopGeneration() {
        generationTask?.cancel()
        SpeechManager.shared.stopAndClear()
    }

    /// Non-async entry point — cancels any in-progress generation instantly, then starts fresh.
    func send(
        _ userText: String,
        includeAmbientCues: Bool = false,
        ambientDuration: TimeInterval? = nil
    ) {
        // Title generation rides on the same LlamaService — cancel it first and await its
        // unwind so the new chat stream doesn't collide with an in-flight title stream.
        titleTask?.cancel()
        generationTask?.cancel()
        let prevTitle = titleTask
        let prevGen = generationTask
        generationTask = Task { @MainActor [weak self] in
            await prevTitle?.value
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

        isGenerating = true

        if hasVisibleUserText {
            conversations[convoIndex].messages.append(ChatMessage(role: .user, content: visibleUserText))
        }
        conversations[convoIndex].updatedAt = Date()
        if hasVisibleUserText {
            autoTitleIfNeeded(convoIndex: convoIndex, userText: visibleUserText)
        }
        saveToDisk()

        // ── Auto-extract personal facts from user message ──────────────────
        if hasVisibleUserText {
            ProfileStore.shared.extractAndSave(from: visibleUserText)
        }

        // ── Build LLM context ──────────────────────────────────────────────
        // 1. User profile — always injected first
        let profileBlock = ProfileStore.shared.systemPromptBlock()

        // 2. Retrieve semantically relevant memories from THIS conversation only.
        // Cross-conversation retrieval is intentionally disabled — see MemoryRetriever.
        let memoryContext = hasVisibleUserText
            ? MemoryRetriever.shared.retrieve(
                query: visibleUserText,
                conversationID: conversations[convoIndex].id,
                topK: 5
            )
            : ""

        // 3. Compose full system prompt
        var fullSystemPrompt = systemPrompt
        if !profileBlock.isEmpty {
            fullSystemPrompt += "\n\n\(profileBlock)"
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
        llmMessages += conversations[convoIndex].messages.map { m in
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
                    let bufferTooLong    = ttsBuffer.count >= 300

                    // Fire on complete sentences immediately — no minimum length guard.
                    // 300-char ceiling only cuts truly runaway sentences.
                    if hitSentenceEnd || hitNewline || bufferTooLong {
                        SpeechManager.shared.enqueue(ttsBuffer)
                        lastEnqueuedAtCount = assistantText.count
                        ttsBuffer = ""
                    }
                }
            }

            if voiceEnabled && !ttsBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SpeechManager.shared.enqueue(ttsBuffer)
            }

            for cue in eligibleAmbientCues {
                conversations[convoIndex].ambientCueLastAcknowledgedTurn[cue.key] = nextUserTurn
            }
            conversations[convoIndex].updatedAt = Date()
            saveToDisk()

            // ── Store exchange in long-term memory (fire-and-forget) ──────
            let cleanedAssistant = conversations[convoIndex].messages[assistantIndex].content
            if !cleanedAssistant.isEmpty {
                if hasVisibleUserText {
                    MemoryRetriever.shared.remember(
                        conversationID: conversations[convoIndex].id,
                        userText: visibleUserText,
                        assistantText: cleanedAssistant
                    )
                }
            }

            // ── Schedule LLM title generation after the 5th user turn ──
            // Earlier turns rely on the exit triggers (chat-switch, app-background)
            // to produce a title for short-lived chats.
            let userTurns = conversations[convoIndex].messages.filter { $0.role == .user }.count
            if hasVisibleUserText && userTurns >= 5 {
                scheduleTitleGeneration(for: conversations[convoIndex].id)
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

    private struct AmbientCue: Equatable {
        let key: String
        let label: String
    }

    private let ambientCueCooldownTurns = 12
    private let maxStoredAmbientEvents = 24

    /// Whisper can return bracketed non-speech markers such as "[Laughter]" or
    /// "[Typing]". Keep them out of the visible transcript, but let the model
    /// react privately when the per-chat cooldown allows it.
    private func extractAmbientCues(from text: String) -> (visibleText: String, cues: [AmbientCue]) {
        let pattern = "\\[([^\\]\\n]{1,48})\\]"
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
            let rawLabel = nsText.substring(with: match.range(at: 1))
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
