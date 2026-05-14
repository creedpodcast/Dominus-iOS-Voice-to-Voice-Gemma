import Foundation

@MainActor
final class ThinkingFillerManager {
    static let shared = ThinkingFillerManager()

    enum PersonalityMode {
        case confident
        case curious
        case analytical
    }

    private enum FillerCategory {
        case greeting
        case core
        case contextual
        case stalling
    }

    private let greetingFillers = [
        "Hey...",
        "Hi...",
        "Yo...",
        "What's good?",
        "I'm here...",
        "What's up?"
    ]

    private let coreFillers = [
        "Hmm...",
        "Let me think...",
        "Okay...",
        "Alright...",
        "Let's see...",
        "Give me a second...",
        "Interesting...",
        "Right..."
    ]

    private let analyticalFillers = [
        "That's a good question...",
        "Let me break that down...",
        "Thinking through this...",
        "There are a few ways to look at this...",
        "Let me work through it...",
        "Alright, here's what I'm seeing..."
    ]

    private let quickFillers = [
        "Got it...",
        "Alright so...",
        "Okay...",
        "Right so...",
        "Makes sense..."
    ]

    private let conversationalFillers = [
        "Honestly...",
        "Actually...",
        "Now that I think about it...",
        "Here's the thing..."
    ]

    private let stallingFillers = [
        "Give me a moment...",
        "Alright... thinking...",
        "Let me sit with that for a second...",
        "Okay... just a second...",
        "Processing that..."
    ]

    private var task: Task<Void, Never>?
    private var generationID = UUID()
    private var recentlyUsed: [String] = []
    private let recentLimit = 6

    private init() {}

    func start(
        for userText: String,
        recentAssistantText: String?,
        personality: PersonalityMode = .curious
    ) {
        cancelScheduling()
        let id = UUID()
        generationID = id

        let plan = makePlan(
            userText: userText,
            recentAssistantText: recentAssistantText,
            personality: personality
        )

        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: plan.firstDelay)
            guard !Task.isCancelled, generationID == id else { return }
            speak(plan.first)

            try? await Task.sleep(nanoseconds: plan.stallDelay)
            guard !Task.isCancelled, generationID == id else { return }
            if let stall = plan.stall {
                speak(stall)
            }
        }
    }

    /// Stop scheduling future filler. Any phrase already handed to TTS is allowed
    /// to finish naturally, so the real response can queue behind it without a hard cut.
    func prepareForRealAnswer() {
        cancelScheduling()
    }

    func cancelScheduling() {
        task?.cancel()
        task = nil
        generationID = UUID()
    }

    private func makePlan(
        userText: String,
        recentAssistantText: String?,
        personality: PersonalityMode
    ) -> (first: String, firstDelay: UInt64, stall: String?, stallDelay: UInt64) {
        let category = chooseCategory(userText: userText, recentAssistantText: recentAssistantText)
        let firstDelay = firstDelay(for: category)
        let first = chooseFiller(
            category: category,
            userText: userText,
            recentAssistantText: recentAssistantText,
            personality: personality
        )
        let shouldAllowStall = category == .stalling || isComplex(userText)
        let stall = shouldAllowStall && Double.random(in: 0...1) < 0.65
            ? chooseUnique(from: stallingFillers)
            : nil
        return (
            first: first,
            firstDelay: firstDelay,
            stall: stall,
            stallDelay: UInt64(Double.random(in: 1.7...2.4) * 1_000_000_000)
        )
    }

    private func chooseCategory(userText: String, recentAssistantText: String?) -> FillerCategory {
        if isGreeting(userText) {
            return .greeting
        }

        let roll = Double.random(in: 0...1)
        if isShort(userText) {
            return roll < 0.70 ? .core : .contextual
        }

        if isComplex(userText) || roll < 0.30 {
            return .contextual
        }
        if roll > 0.90 {
            return .stalling
        }
        if isFollowUp(userText, recentAssistantText: recentAssistantText) {
            return .contextual
        }
        return .core
    }

    private func chooseFiller(
        category: FillerCategory,
        userText: String,
        recentAssistantText: String?,
        personality: PersonalityMode
    ) -> String {
        if isShort(userText), category != .stalling {
            return chooseUnique(from: category == .greeting ? greetingFillers : quickFillers)
        }

        switch category {
        case .greeting:
            return chooseUnique(from: greetingFillers)
        case .core:
            return chooseUnique(from: personalitySeed(personality) + coreFillers)
        case .contextual:
            if isFollowUp(userText, recentAssistantText: recentAssistantText) {
                return chooseUnique(from: conversationalFillers + quickFillers)
            }
            return chooseUnique(from: personalitySeed(personality) + analyticalFillers + conversationalFillers)
        case .stalling:
            return chooseUnique(from: stallingFillers)
        }
    }

    private func firstDelay(for category: FillerCategory) -> UInt64 {
        let seconds: Double
        switch category {
        case .greeting:
            seconds = Double.random(in: 0.15...0.35)
        case .core:
            seconds = Double.random(in: 0.45...0.9)
        case .contextual:
            seconds = Double.random(in: 0.55...1.1)
        case .stalling:
            seconds = Double.random(in: 1.0...1.5)
        }
        return UInt64(seconds * 1_000_000_000)
    }

    private func personalitySeed(_ personality: PersonalityMode) -> [String] {
        switch personality {
        case .confident:
            return ["Alright...", "Okay..."]
        case .curious:
            return ["Hmm...", "Interesting..."]
        case .analytical:
            return ["Let me think through that...", "Let me break that down..."]
        }
    }

    private func speak(_ phrase: String) {
        remember(phrase)
        SpeechManager.shared.enqueue(phrase)
    }

    private func chooseUnique(from phrases: [String]) -> String {
        let available = phrases.filter { !recentlyUsed.contains($0) }
        return (available.isEmpty ? phrases : available).randomElement() ?? "Hmm..."
    }

    private func remember(_ phrase: String) {
        recentlyUsed.append(phrase)
        if recentlyUsed.count > recentLimit {
            recentlyUsed.removeFirst(recentlyUsed.count - recentLimit)
        }
    }

    private func isShort(_ text: String) -> Bool {
        text.split(separator: " ").count <= 5
    }

    private func isGreeting(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "[^a-z\\s']", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let greetings = [
            "hello",
            "hi",
            "hey",
            "yo",
            "what's up",
            "whats up",
            "how are you",
            "how are you today",
            "how's it going",
            "hows it going"
        ]
        return greetings.contains(normalized)
    }

    private func isComplex(_ text: String) -> Bool {
        let words = text.split(separator: " ").count
        let lowered = text.lowercased()
        return words > 18
            || lowered.contains("why")
            || lowered.contains("how")
            || lowered.contains("explain")
            || lowered.contains("compare")
            || lowered.contains("break down")
    }

    private func isFollowUp(_ text: String, recentAssistantText: String?) -> Bool {
        guard recentAssistantText != nil else { return false }
        let lowered = text.lowercased()
        let followUpCues = [
            "what about",
            "but",
            "so",
            "then",
            "also",
            "what else",
            "why is that",
            "how so"
        ]
        return followUpCues.contains { lowered.contains($0) }
    }
}
