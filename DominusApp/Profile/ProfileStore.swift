import Foundation
import SwiftData

/// Stores and retrieves persistent facts about the user.
/// Facts are injected into every system prompt so Dominus always knows who it's talking to.
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
    func systemPromptBlock() -> String {
        var parts: [String] = []

        if !facts.isEmpty {
            let lines = facts.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")
            parts.append("What you know about the user:\n\(lines)")
        }

        let p = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty {
            parts.append("How to talk to this user:\n\(p)")
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Auto-extract facts from conversation

    /// Scans a user message for personal facts and saves them automatically.
    /// Patterns detected: "my name is X", "I am X years old", "I live in X",
    /// "my favorite X is Y", "I work as X", "I am from X"
    func extractAndSave(from userText: String) {
        let text = userText.lowercased()

        let patterns: [(pattern: String, key: String)] = [
            ("my name is ",          "name"),
            ("i'm called ",          "name"),
            ("call me ",             "name"),
            ("i am (\\d+) years old","age"),
            ("i'm (\\d+) years old", "age"),
            ("i live in ",           "location"),
            ("i'm from ",            "origin"),
            ("i am from ",           "origin"),
            ("i work as ",           "occupation"),
            ("i work in ",           "industry"),
            ("i'm a ",               "role"),
            ("i am a ",              "role"),
            ("my favorite color is ","favorite color"),
            ("my favorite food is ", "favorite food"),
            ("my favorite music is ","favorite music"),
            ("i love ",              "interest"),
            ("i enjoy ",             "interest"),
            ("i hate ",              "dislike"),
            ("i speak ",             "language"),
        ]

        for (pattern, key) in patterns {
            if let range = text.range(of: pattern) {
                // Extract the value — everything after the pattern up to punctuation
                let after = String(text[range.upperBound...])
                let value = after
                    .components(separatedBy: CharacterSet(charactersIn: ".!?,\n"))
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if !value.isEmpty && value.split(separator: " ").count <= 8 {
                    // Capitalise properly
                    let formatted = value.prefix(1).uppercased() + value.dropFirst()
                    upsert(key: key, value: formatted)
                }
            }
        }
    }
}
