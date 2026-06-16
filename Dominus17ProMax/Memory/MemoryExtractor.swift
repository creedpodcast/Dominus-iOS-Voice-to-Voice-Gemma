import Foundation

struct ExtractedMemoryAtom: Hashable {
    var kind: MemoryKind
    var categoryKey: String
    var title: String
    var content: String
}

enum MemoryExtractor {
    static func extract(
        from text: String,
        defaultKind: MemoryKind = .userFact,
        defaultCategoryKey: String = MemoryHubCategory.general.rawValue,
        maxAtoms: Int = 8
    ) -> [ExtractedMemoryAtom] {
        let cleaned = text
            .replacingOccurrences(of: "Recent conversation to remember:", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        let userText = cleaned
            .components(separatedBy: .newlines)
            .compactMap(userLine)
            .joined(separator: "\n")
        guard !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var atoms: [ExtractedMemoryAtom] = []
        atoms.append(contentsOf: listAtoms(from: userText))
        atoms.append(contentsOf: sentenceAtoms(from: userText))

        let unique = atoms.reduce(into: [ExtractedMemoryAtom]()) { result, atom in
            guard !atom.content.isEmpty else { return }
            let key = normalizedKey(atom.content)
            guard !result.contains(where: { normalizedKey($0.content) == key }) else { return }
            result.append(atom)
        }

        if !unique.isEmpty {
            return Array(unique.prefix(maxAtoms))
        }

        let fallback = normalizedStatement(userText)
        guard !fallback.isEmpty else { return [] }
        return [
            ExtractedMemoryAtom(
                kind: defaultKind,
                categoryKey: defaultCategoryKey,
                title: title(for: defaultKind, content: fallback),
                content: fallback
            )
        ]
    }

    static func preview(_ atoms: [ExtractedMemoryAtom]) -> String {
        atoms.map(\.content).joined(separator: "\n")
    }

    private static func userLine(_ rawLine: String) -> String? {
        let line = rawLine
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        if line.range(of: #"(?i)^(Dominus|Assistant|AI|Model):"#, options: .regularExpression) != nil {
            return nil
        }
        return line.replacingOccurrences(of: #"(?i)^User:\s*"#, with: "", options: .regularExpression)
    }

    private static func listAtoms(from text: String) -> [ExtractedMemoryAtom] {
        var atoms: [ExtractedMemoryAtom] = []
        atoms.append(contentsOf: extractList(
            from: text,
            pattern: #"(?i)\b(?:read|reading)\s+(.+?)(?=,?\s+(?:and\s+)?(?:i\s+need|i\s+want|i\s+am|i'm|take|taking)\b|[.!?\n]|$)"#,
            kind: .goal,
            categoryKey: MemoryHubCategory.writing.rawValue,
            title: "Book",
            verb: "Creed wants to read"
        ))
        atoms.append(contentsOf: extractList(
            from: text,
            pattern: #"(?i)\b(?:take|taking|considering)\s+(.+?(?:course|class|training).*?)(?=,?\s+(?:and\s+)?(?:i\s+need|i\s+want|i\s+am|i'm|read|reading)\b|[.!?\n]|$)"#,
            kind: .goal,
            categoryKey: MemoryHubCategory.projects.rawValue,
            title: "Course",
            verb: "Creed is considering"
        ))
        return atoms
    }

    private static func extractList(
        from text: String,
        pattern: String,
        kind: MemoryKind,
        categoryKey: String,
        title: String,
        verb: String
    ) -> [ExtractedMemoryAtom] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, range: fullRange).flatMap { match -> [ExtractedMemoryAtom] in
            guard match.numberOfRanges > 1 else { return [] }
            let capture = nsText.substring(with: match.range(at: 1))
            return splitItems(capture).map {
                let item = cleanedItemTitle($0)
                return ExtractedMemoryAtom(
                    kind: kind,
                    categoryKey: categoryKey,
                    title: "\(title): \(item)",
                    content: "\(verb) \(item)"
                )
            }
        }
    }

    private static func sentenceAtoms(from text: String) -> [ExtractedMemoryAtom] {
        splitSentences(text).compactMap { sentence in
            let lower = sentence.lowercased()
            if sentence.contains(","),
               lower.contains("read") || lower.contains("book") || lower.contains("course") || lower.contains("class") {
                return nil
            }
            let normalized = normalizedStatement(sentence)
            guard !normalized.isEmpty else { return nil }
            let kind = kindFor(sentence: normalized)
            return ExtractedMemoryAtom(
                kind: kind,
                categoryKey: categoryFor(kind: kind, sentence: normalized),
                title: title(for: kind, content: normalized),
                content: normalized
            )
        }
    }

    private static func splitSentences(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".!?\n;"))
            .flatMap(splitCompoundIdeas)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 }
    }

    private static func splitCompoundIdeas(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let marked = normalized.replacingOccurrences(
            of: #"(?i)\s+(and also|also|plus)\s+"#,
            with: "|||",
            options: .regularExpression
        )
        let pieces = marked.components(separatedBy: "|||")
        return pieces.count > 1 ? pieces : [normalized]
    }

    private static func splitItems(_ text: String) -> [String] {
        text.replacingOccurrences(of: #"(?i)\b(and|plus)\b"#, with: ",", options: .regularExpression)
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    private static func normalizedStatement(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-• "))

        text = text.replacingOccurrences(
            of: #"(?i)^(please\s+)?(?:remember|remembering|save|memorize)\s+(?:this|that|it)?\s*:?\s*"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?i)^i\s+want\s+you\s+to\s+(?:remember|save|memorize)\s+(?:this|that|it)?\s*:?\s*"#,
            with: "",
            options: .regularExpression
        )
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        while text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") {
            text.removeLast()
        }

        let replacements: [(String, String)] = [
            (#"(?i)^i\s+love\s+(.+)$"#, "Creed likes $1"),
            (#"(?i)^i\s+like\s+(.+)$"#, "Creed likes $1"),
            (#"(?i)^i\s+enjoy\s+(.+)$"#, "Creed enjoys $1"),
            (#"(?i)^i\s+prefer\s+(.+)$"#, "Creed prefers $1"),
            (#"(?i)^my\s+favorite\s+(.+?)\s+is\s+(.+)$"#, "Creed's favorite $1 is $2"),
            (#"(?i)^my\s+(.+?)\s+is\s+(.+)$"#, "Creed's $1 is $2"),
            (#"(?i)^i(?:'m| am)\s+writing\s+(.+)$"#, "Creed is writing $1"),
            (#"(?i)^i(?:'m| am)\s+interested\s+in\s+(.+)$"#, "Creed is interested in $1"),
            (#"(?i)^i(?:'m| am)\s+thinking\s+about\s+(.+)$"#, "Creed is considering $1"),
            (#"(?i)^i(?:'m| am)\s+considering\s+(.+)$"#, "Creed is considering $1"),
            (#"(?i)^i\s+(?:am\s+)?working\s+on\s+(.+)$"#, "Creed is working on $1"),
            (#"(?i)^i\s+want\s+to\s+(.+)$"#, "Creed wants to $1"),
            (#"(?i)^i\s+need\s+to\s+(.+)$"#, "Creed needs to $1"),
            (#"(?i)^i\s+plan\s+to\s+(.+)$"#, "Creed plans to $1"),
            (#"(?i)^i\s+will\s+not\s+(.+)$"#, "Creed will not $1"),
            (#"(?i)^i\s+won't\s+(.+)$"#, "Creed will not $1"),
            (#"(?i)^i\s+will\s+(.+)$"#, "Creed will $1"),
            (#"(?i)^i\s+might\s+(.+)$"#, "Creed may $1"),
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
            text = inferredThirdPersonStatement(from: text)
        }
        return String(text.prefix(1)).uppercased() + String(text.dropFirst())
    }

    private static func inferredThirdPersonStatement(from text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = clean.lowercased()
        if lower.contains("thinking about") {
            return "Creed is considering \(clean.replacingOccurrences(of: #"(?i).*?\bthinking about\s+"#, with: "", options: .regularExpression))"
        }
        if lower.contains("considering") {
            return "Creed is considering \(clean.replacingOccurrences(of: #"(?i).*?\bconsidering\s+"#, with: "", options: .regularExpression))"
        }
        if lower.contains("interested in") {
            return "Creed is interested in \(clean.replacingOccurrences(of: #"(?i).*?\binterested in\s+"#, with: "", options: .regularExpression))"
        }
        if lower.contains("wants to") || lower.contains("want to") {
            return clean.replacingOccurrences(of: #"(?i).*?\bwants?\s+to\s+"#, with: "Creed wants to ", options: .regularExpression)
        }
        if lower.contains("needs to") || lower.contains("need to") {
            return clean.replacingOccurrences(of: #"(?i).*?\bneeds?\s+to\s+"#, with: "Creed needs to ", options: .regularExpression)
        }
        return "Creed noted \(clean)"
    }

    private static func kindFor(sentence: String) -> MemoryKind {
        let lower = sentence.lowercased()
        if lower.contains("favorite") || lower.contains("likes") || lower.contains("prefers") {
            return .preference
        }
        if lower.contains("goal") || lower.contains("wants to") || lower.contains("plans to") || lower.contains("needs to") || lower.contains("interested in") || lower.contains("considering") {
            return .goal
        }
        if lower.contains("book") || lower.contains("course") || lower.contains("project") || lower.contains("working on") {
            return .taskReference
        }
        return .userFact
    }

    private static func categoryFor(kind: MemoryKind, sentence: String) -> String {
        let lower = sentence.lowercased()
        if lower.contains("gym") || lower.contains("workout") || lower.contains("fitness") {
            return MemoryHubCategory.health.rawValue
        }
        if lower.contains("book") || lower.contains("writing") || lower.contains("bible") {
            return MemoryHubCategory.writing.rawValue
        }
        if lower.contains("course") || lower.contains("project") {
            return MemoryHubCategory.projects.rawValue
        }
        if kind == .preference {
            return MemoryHubCategory.preferences.rawValue
        }
        if kind == .goal {
            return MemoryHubCategory.goals.rawValue
        }
        return MemoryHubCategory.general.rawValue
    }

    private static func title(for kind: MemoryKind, content: String) -> String {
        let lower = content.lowercased()
        if lower.contains("gym") || lower.contains("workout") {
            return "Schedule: Gym"
        }
        if lower.contains("favorite") {
            return compactTitle(from: content, fallback: "Favorite")
        }
        if lower.contains("interested in") {
            return compactTitle(from: content, fallback: "Interest")
        }
        if lower.contains("considering") {
            return compactTitle(from: content, fallback: "Consideration")
        }
        if lower.contains("bible") || lower.contains("scripture") || lower.contains("passage") || lower.contains("verse") {
            return "Bible Study"
        }
        if lower.contains("book") || lower.contains("writing") {
            return compactTitle(from: content, fallback: "Writing")
        }
        if lower.contains("course") || lower.contains("class") {
            return compactTitle(from: content, fallback: "Course")
        }
        if lower.contains("project") {
            return compactTitle(from: content, fallback: "Project")
        }
        switch kind {
        case .preference: return compactTitle(from: content, fallback: "Preference")
        case .goal: return compactTitle(from: content, fallback: "Goal")
        case .taskReference: return compactTitle(from: content, fallback: "Task")
        case .wikiEntry: return "Reference"
        default: return compactTitle(from: content, fallback: "Memory")
        }
    }

    private static func compactTitle(from content: String, fallback: String) -> String {
        var text = content.replacingOccurrences(
            of: #"(?i)^creed(?:'s| is| wants to| needs to| plans to| likes| enjoys| prefers| noted| will| may)?\s*"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?i)^(favorite|interested in|considering|working on|writing|read|reading)\s+"#,
            with: "",
            options: .regularExpression
        )
        let words = text
            .split(separator: " ")
            .prefix(5)
            .map { word in
                word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return fallback }
        let title = words.joined(separator: " ")
        return String(title.prefix(1)).uppercased() + String(title.dropFirst())
    }

    private static func cleanedItemTitle(_ item: String) -> String {
        item.replacingOccurrences(of: #"(?i)^(a|an|the)\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedKey(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
