import Foundation

enum MemorySummaryBuilder {
    static func chatBubbleSummary(from text: String, isUser: Bool, maxBullets: Int = 3) -> String {
        if isUser {
            return bulletSummary(from: "User: \(text)", maxBullets: maxBullets)
        }
        return assistantSummary(from: text, maxBullets: maxBullets)
    }

    static func bulletSummary(from text: String, maxBullets: Int = 5) -> String {
        let atoms = MemoryExtractor.extract(from: text, maxAtoms: maxBullets)
        return MemoryExtractor.preview(atoms)
    }

    static func summary(from text: String, maxItems: Int = 5) -> String? {
        let atoms = MemoryExtractor.extract(from: text, maxAtoms: maxItems)
        guard !atoms.isEmpty else { return nil }
        return MemoryExtractor.preview(atoms)
    }

    private static func assistantSummary(from text: String, maxBullets: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        let parts = cleaned
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 }

        let source = parts.isEmpty ? [cleaned] : parts
        let bullets = source
            .prefix(maxBullets)
            .map { item -> String in
                let capped = item.count > 180
                    ? String(item.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
                    : item
                return "Dominus response note: \(capped)"
            }

        return bullets.joined(separator: "\n")
    }

    private static func splitMemoryIdeas(from text: String) -> [String] {
        let userOnlyText = text
            .components(separatedBy: .newlines)
            .compactMap(userMemoryLine)
            .joined(separator: "\n")

        let roughParts = userOnlyText
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 }

        if roughParts.count > 1 {
            return roughParts
        }

        return [userOnlyText.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    private static func userMemoryLine(_ rawLine: String) -> String? {
        let line = rawLine
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        if line.range(of: #"(?i)^(Dominus|Assistant|AI|Model):"#, options: .regularExpression) != nil {
            return nil
        }

        return line.replacingOccurrences(
            of: #"(?i)^User:\s*"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func normalizedStatement(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-• "))

        while text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") {
            text.removeLast()
        }

        let replacements: [(String, String)] = [
            (#"(?i)^i\s+love\s+(.+)$"#, "Creed likes $1"),
            (#"(?i)^i\s+like\s+(.+)$"#, "Creed likes $1"),
            (#"(?i)^i\s+enjoy\s+(.+)$"#, "Creed enjoys $1"),
            (#"(?i)^i\s+prefer\s+(.+)$"#, "Creed prefers $1"),
            (#"(?i)^my\s+favorite\s+(.+?)\s+is\s+(.+)$"#, "Creed's favorite $1 is $2"),
            (#"(?i)^my\s+favourite\s+(.+?)\s+is\s+(.+)$"#, "Creed's favorite $1 is $2"),
            (#"(?i)^my\s+(.+?)\s+is\s+(.+)$"#, "Creed's $1 is $2"),
            (#"(?i)^i(?:'m| am)\s+writing\s+(.+)$"#, "Creed is writing $1"),
            (#"(?i)^i\s+(?:am\s+)?working\s+on\s+(.+)$"#, "Creed is working on $1"),
            (#"(?i)^i\s+want\s+to\s+(.+)$"#, "Creed wants to $1"),
            (#"(?i)^i\s+am\s+(.+)$"#, "Creed is $1"),
            (#"(?i)^i'm\s+(.+)$"#, "Creed is $1")
        ]

        for (pattern, replacement) in replacements {
            let updated = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
            if updated != text {
                text = updated
                break
            }
        }

        if text.range(of: #"(?i)\b(creed|user|dominus)\b"#, options: .regularExpression) == nil {
            text = "Creed noted \(text)"
        }

        guard !text.isEmpty else { return "" }
        return String(text.prefix(1)).uppercased() + String(text.dropFirst())
    }

    private static func normalizedKey(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
