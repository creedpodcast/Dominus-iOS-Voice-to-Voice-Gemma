import Foundation
import SwiftData

/// Stores and retrieves the small user-controlled profile block.
/// The profile is intentionally limited so it stays useful without crowding the local context window.
@MainActor
@Observable
final class ProfileStore {

    static let shared = ProfileStore()

    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// Observable so the UI can display/edit the profile
    var facts: [ProfileFact] = []

    /// Free-text instructions for how Dominus should speak/behave.
    /// Persisted in UserDefaults so no SwiftData migration is needed.
    var persona: String {
        get { UserDefaults.standard.string(forKey: "dominus_persona") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "dominus_persona") }
    }

    /// When true, voice-to-voice replies are asked to end with an emoji.
    /// User-controlled in Profile under the "How Dominus Should Talk" area.
    /// Persisted in UserDefaults. Defaults to `true` so the orb has something
    /// to show out of the box; the user can disable it any time.
    var voiceEmojisEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "dominus_voice_emojis") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "dominus_voice_emojis")
        }
        set { UserDefaults.standard.set(newValue, forKey: "dominus_voice_emojis") }
    }

    var displayName: String {
        value(for: Self.displayNameKey)
    }

    var appPurpose: String {
        value(for: Self.appPurposeKey)
    }

    var jobTitle: String {
        value(for: Self.jobTitleKey)
    }

    var goals: [String] {
        Self.goalKeys.map(value(for:))
    }

    var behaviorNotes: [String] {
        Self.behaviorKeys.map(value(for:))
    }

    private static let displayNameKey = "name"
    private static let appPurposeKey = "app purpose"
    private static let jobTitleKey = "role or work"
    private static let goalKeys = ["goal 1", "goal 2", "goal 3"]
    private static let behaviorKeys = ["behavior 1", "behavior 2", "behavior 3"]

    init() {
        do {
            container = try ModelContainer(for: ProfileFact.self)
        } catch {
            fatalError("ProfileStore: failed to create SwiftData container — \(error)")
        }
        loadFacts()
    }

    // MARK: - Load

    func loadFacts() {
        let descriptor = FetchDescriptor<ProfileFact>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        facts = (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Upsert

    /// Adds or updates a fact. If a fact with the same key already exists, it's updated.
    func upsert(key: String, value: String) {
        let trimmedKey   = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedValue.isEmpty else { return }

        if let existing = facts.first(where: { $0.key == trimmedKey }) {
            existing.value     = trimmedValue
            existing.updatedAt = Date()
        } else {
            let fact = ProfileFact(key: trimmedKey, value: trimmedValue)
            context.insert(fact)
        }
        try? context.save()
        loadFacts()
        print("👤 Profile upserted: \(trimmedKey) = \(trimmedValue)")
    }

    func updateDisplayName(_ value: String) {
        updateProfileField(key: Self.displayNameKey, value: value)
    }

    func updateAppPurpose(_ value: String) {
        updateProfileField(key: Self.appPurposeKey, value: value)
    }

    func updateJobTitle(_ value: String) {
        updateProfileField(key: Self.jobTitleKey, value: value)
    }

    func updateGoals(_ values: [String]) {
        updateListFields(keys: Self.goalKeys, values: values)
    }

    func updateBehaviorNotes(_ values: [String]) {
        updateListFields(keys: Self.behaviorKeys, values: values)
    }

    // MARK: - Delete

    func delete(_ fact: ProfileFact) {
        context.delete(fact)
        try? context.save()
        loadFacts()
    }

    func deleteAll() {
        facts.forEach { context.delete($0) }
        try? context.save()
        loadFacts()
    }

    // MARK: - System prompt injection

    /// Returns a compact string to prepend to the system prompt.
    /// Empty string when neither facts nor persona exist.
    /// - Parameter voiceMode: when true and the user has the voice-emoji
    ///   preference enabled, appends an emoji directive to the "How to talk"
    ///   block so voice-mode replies always carry an end-of-response emoji.
    func systemPromptBlock(voiceMode: Bool = false) -> String {
        var parts: [String] = []

        let profileLines = structuredProfileLines()
        if !profileLines.isEmpty {
            parts.append("""
            User profile:
            \(profileLines.joined(separator: "\n"))
            Use this profile as stable user context. Keep it secondary to the user's latest message.
            """)
        }

        // "How to talk to this user" — user-typed persona + (voice-only)
        // emoji preference, combined so the model treats them as one block.
        var talkLines: [String] = []
        let p = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { talkLines.append(p) }
        if voiceMode && voiceEmojisEnabled {
            talkLines.append("Use an emoji at the end of every response.")
        }
        if !talkLines.isEmpty {
            parts.append("How to talk to this user:\n\(talkLines.joined(separator: "\n"))")
        }

        return parts.joined(separator: "\n\n")
    }

    private func structuredProfileLines() -> [String] {
        var lines: [String] = []
        if !displayName.isEmpty { lines.append("- preferred name: \(displayName)") }
        if !jobTitle.isEmpty { lines.append("- role/work: \(jobTitle)") }
        if !appPurpose.isEmpty { lines.append("- why they use Dominus: \(appPurpose)") }

        let cleanGoals = goals.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !cleanGoals.isEmpty {
            lines.append("- current goals: \(cleanGoals.joined(separator: "; "))")
        }

        let cleanBehavior = behaviorNotes.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !cleanBehavior.isEmpty {
            lines.append("- behavior preferences: \(cleanBehavior.joined(separator: "; "))")
        }

        return lines
    }

    private static let allowedProfileKeys: Set<String> = Set([
        displayNameKey,
        appPurposeKey,
        jobTitleKey
    ] + goalKeys + behaviorKeys)

    private func value(for key: String) -> String {
        facts.first { $0.key == key }?.value ?? ""
    }

    private func updateProfileField(key: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if let existing = facts.first(where: { $0.key == key }) {
                delete(existing)
            }
        } else {
            upsert(key: key, value: trimmed)
        }
    }

    private func updateListFields(keys: [String], values: [String]) {
        for (index, key) in keys.enumerated() {
            updateProfileField(key: key, value: values.indices.contains(index) ? values[index] : "")
        }
    }
}
