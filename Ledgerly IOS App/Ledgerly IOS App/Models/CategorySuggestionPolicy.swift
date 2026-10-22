import Foundation

/// Conservative gate for the generic model. A saved user choice can still match these titles.
enum CategorySuggestionPolicy {
    static let minimumConfidence = 0.30
    static let minimumMargin = 0.25

    /// Low-confidence options are only choices to inspect, never reliable suggestions.
    static func alternatives(scores: [CategoryRankedScore], title: String, kind: EntryKind,
                             activeCategories: [LedgerCategory], source: CategoryMatch,
                             modelVersion: UUID? = nil) -> [CategoryAlternative] {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4,
              hasDistinctiveDescription(title), source == .model || source == .personalModel else { return [] }
        let prefix = kind == .expense ? "expense|" : "income|"
        let active = activeCategories.filter { $0.kind == kind && !$0.isArchived }
        let mapped: [(CategoryAlternative, Double)] = scores.compactMap { score in
            guard score.score.isFinite, (0.05...1).contains(score.score) else { return nil }
            if let similarity = score.similarity {
                guard similarity.isFinite, (0.55...1.000_001).contains(similarity) else { return nil }
            }
            let category: LedgerCategory?
            if source == .personalModel {
                category = UUID(uuidString: score.label).flatMap { id in active.first { $0.id == id } }
            } else {
                guard score.label.hasPrefix(prefix) else { return nil }
                let name = String(score.label.dropFirst(prefix.count))
                category = active.first {
                    $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }
            }
            guard let category else { return nil }
            return (.init(categoryID: category.id, name: category.name, source: source,
                          modelVersion: modelVersion), score.score)
        }
        var seen: Set<UUID> = []
        return Array(mapped.sorted {
            $0.1 == $1.1 ? $0.0.id.uuidString < $1.0.id.uuidString : $0.1 > $1.1
        }.compactMap { option, _ in seen.insert(option.id).inserted ? option : nil }.prefix(3))
    }

    private static let genericWords: Set<String> = [
        "a", "an", "the", "for", "from", "to", "of", "my", "your", "at", "in", "on",
        "bank", "cash", "card", "credit", "debit", "account", "transfer", "transferred",
        "deposit", "deposited", "withdrawal", "withdrawn", "payment", "paid", "receipt",
        "transaction", "received", "sent", "money", "amount", "lkr", "rs"
    ]

    static func hasDistinctiveDescription(_ title: String) -> Bool {
        let words = title.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        return words.contains { !genericWords.contains($0) }
    }

    static func accepts(kindPrefix: String, title: String, label: String,
                        confidence: Double, secondConfidence: Double) -> Bool {
        guard hasDistinctiveDescription(title),
              label.hasPrefix("\(kindPrefix)|"),
              confidence >= minimumConfidence,
              confidence - secondConfidence >= minimumMargin else { return false }
        return true
    }
}
