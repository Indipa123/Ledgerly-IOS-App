import Foundation

nonisolated enum CategoryMatch: String, Codable, Equatable, Sendable {
    case exact
    case similar
    case model
    case personalModel
    case place

    var label: String {
        switch self {
        case .exact: "Previous saved choices"
        case .similar: "Similar description"
        case .model: "Suggested from description"
        case .personalModel: "Personalised suggestion"
        case .place: "Expenses at this place"
        }
    }
}

struct CategoryMemorySuggestion: Equatable {
    let categoryID: UUID
    let exampleCount: Int
    let match: CategoryMatch
    var modelVersion: UUID? = nil
    var estimatedCorrectness: Double? = nil
}

nonisolated struct CategoryRankedScore: Sendable {
    let label: String
    let score: Double
    var similarity: Double? = nil
}

nonisolated struct CategoryAlternative: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { categoryID }
    let categoryID: UUID
    let name: String
    let source: CategoryMatch
    var modelVersion: UUID? = nil
}

struct CategoryAssistance {
    var suggestion: CategoryMemorySuggestion? = nil
    var alternatives: [CategoryAlternative] = []
}

/// Outcomes only: intermediate descriptions, amounts and coordinates are never retained.
nonisolated struct CategoryPredictionOutcome: Codable, Equatable, Sendable {
    let kind: Int16
    let source: CategoryMatch?
    let suggestedCategoryID: UUID?
    let suggestedCategoryName: String?
    var modelVersion: UUID? = nil
    var alternatives: [CategoryAlternative] = []
}

nonisolated struct CategoryPredictionEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordedAt: Date
    let outcome: CategoryPredictionOutcome
}

nonisolated struct CategoryPredictionHistory: Codable, Equatable, Sendable {
    static let limit = 20
    private(set) var events: [CategoryPredictionEvent] = []
    private(set) var omittedCount = 0

    mutating func append(_ outcome: CategoryPredictionOutcome, at date: Date = .now) {
        guard events.last?.outcome != outcome else { return }
        events.append(.init(id: UUID(), recordedAt: date, outcome: outcome))
        if events.count > Self.limit {
            let excess = events.count - Self.limit
            events.removeFirst(excess)
            omittedCount += excess
        }
    }
}

/// A first-save snapshot; a present record with no source means an observed abstention.
/// Category names are historical; later renames or edits must not rewrite the evidence.
nonisolated struct CategorySuggestionRecord: Codable, Equatable {
    let source: CategoryMatch?
    let suggestedCategoryID: UUID?
    let suggestedCategoryName: String?
    let savedCategoryID: UUID
    let savedCategoryName: String
    let kind: Int16
    let recordedAt: Date
    var modelVersion: UUID? = nil
    var review: CategoryReviewAcknowledgement? = nil
    var alternatives: [CategoryAlternative]? = nil
    var predictionHistory: CategoryPredictionHistory? = nil

    var wasAccepted: Bool? { suggestedCategoryID.map { $0 == savedCategoryID } }

    func categoryChanged(categoryID: UUID?, kind: Int16) -> Bool {
        self.kind != kind || savedCategoryID != categoryID
    }
}

nonisolated struct CategoryReviewAcknowledgement: Codable, Equatable {
    let categoryID: UUID
    let kind: Int16
    let title: String
    let reviewedAt: Date

    func matches(categoryID: UUID?, kind: Int16, title: String) -> Bool {
        self.categoryID == categoryID && self.kind == kind && self.title == title
    }
}

enum CategoryReviewQueue {
    /// Never infer historical abstention from missing evidence or from a new prediction.
    static func pending(entries: [LedgerEntry], excludedEntryIDs: Set<UUID> = [],
                        asOf: Date = .now) -> [LedgerEntry] {
        matching(entries: entries, excludedEntryIDs: excludedEntryIDs, asOf: asOf, reviewed: false)
    }

    static func reviewed(entries: [LedgerEntry], excludedEntryIDs: Set<UUID> = [],
                         asOf: Date = .now) -> [LedgerEntry] {
        matching(entries: entries, excludedEntryIDs: excludedEntryIDs, asOf: asOf, reviewed: true)
    }

    private static func matching(entries: [LedgerEntry], excludedEntryIDs: Set<UUID>,
                                 asOf: Date, reviewed: Bool) -> [LedgerEntry] {
        entries.filter { entry in
            guard let record = entry.categorySuggestion, record.source == nil,
                  entry.categoryID != nil, entry.date <= asOf,
                  !excludedEntryIDs.contains(entry.id),
                  !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            let isCurrentReview = record.review?.matches(categoryID: entry.categoryID,
                kind: entry.kind.rawValue, title: entry.title) == true
            return isCurrentReview == reviewed
        }.sorted {
            let firstDate = reviewed ? $0.categorySuggestion?.review?.reviewedAt ?? $0.date : $0.date
            let secondDate = reviewed ? $1.categorySuggestion?.review?.reviewedAt ?? $1.date : $1.date
            if firstDate != secondDate { return firstDate > secondDate }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

struct CategoryLearningGroup: Identifiable {
    let id: String
    let title: String
    let kind: EntryKind
    let exampleCount: Int
    let categoryCounts: [UUID: Int]
    let entryIDs: Set<UUID>

    var hasMixedCategories: Bool { categoryCounts.count > 1 }
}

enum CategoryLearningReview {
    static func excludedExamples(entries: [LedgerEntry], excludedEntryIDs: Set<UUID>,
                                 search: String = "", kind: EntryKind? = nil) -> [LedgerEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = CategoryMemoryIndex.normalized(query)
        return entries.filter { entry in
            excludedEntryIDs.contains(entry.id) && (kind == nil || entry.kind == kind) &&
            (query.isEmpty || entry.title.localizedStandardContains(query) ||
             entry.category.localizedStandardContains(query) ||
             (!normalizedQuery.isEmpty &&
              (CategoryMemoryIndex.normalized(entry.title).contains(normalizedQuery) ||
               CategoryMemoryIndex.normalized(entry.category).contains(normalizedQuery))))
        }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Removed entries retain their exclusion so deletion Undo cannot re-enable learning.
    static func restoringExamples(_ ids: Set<UUID>, excludedEntryIDs: Set<UUID>,
                                  entries: [LedgerEntry]) -> Set<UUID> {
        excludedEntryIDs.subtracting(ids.intersection(Set(entries.map(\.id))))
    }

    /// Different saved labels deserve review, but may be intentional (for example a supermarket meal).
    static func groups(_ groups: [CategoryLearningGroup], search: String = "",
                       mixedOnly: Bool = false) -> [CategoryLearningGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = CategoryMemoryIndex.normalized(query)
        return groups.filter { group in
            (!mixedOnly || group.hasMixedCategories) &&
            (query.isEmpty || group.title.localizedStandardContains(query) ||
             (!normalizedQuery.isEmpty && CategoryMemoryIndex.normalized(group.title).contains(normalizedQuery)))
        }.sorted {
            if $0.hasMixedCategories != $1.hasMixedCategories { return $0.hasMixedCategories }
            if $0.exampleCount != $1.exampleCount { return $0.exampleCount > $1.exampleCount }
            let order = $0.title.localizedCaseInsensitiveCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    static func examples(in group: CategoryLearningGroup, entries: [LedgerEntry]) -> [LedgerEntry] {
        entries.filter { group.entryIDs.contains($0.id) }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

/// Learns only from transactions whose category the user saved. An uncertain match abstains.
struct CategoryMemoryIndex {
    private struct Key: Hashable {
        let kind: EntryKind
        let merchant: String
    }

    private struct TrigramKey: Hashable {
        let kind: EntryKind
        let value: String
    }

    private var counts: [Key: [UUID: Int]] = [:]
    private var keysByTrigram: [TrigramKey: Set<Key>] = [:]

    init(entries: [LedgerEntry], excludedEntryIDs: Set<UUID> = []) {
        for entry in entries {
            guard !excludedEntryIDs.contains(entry.id) else { continue }
            guard let categoryID = entry.categoryID else { continue }
            let merchant = Self.normalized(entry.title)
            guard merchant.count >= 4 else { continue }
            let key = Key(kind: entry.kind, merchant: merchant)
            if counts[key] == nil {
                for trigram in Self.trigrams(merchant).keys {
                    keysByTrigram[TrigramKey(kind: entry.kind, value: trigram), default: []].insert(key)
                }
            }
            counts[key, default: [:]][categoryID, default: 0] += 1
        }
    }

    static func groups(entries: [LedgerEntry], excludedEntryIDs: Set<UUID> = []) -> [CategoryLearningGroup] {
        struct Draft {
            var title: String
            var kind: EntryKind
            var categoryCounts: [UUID: Int]
            var entryIDs: Set<UUID>
        }
        var grouped: [String: Draft] = [:]
        for entry in entries {
            guard !excludedEntryIDs.contains(entry.id), let categoryID = entry.categoryID else { continue }
            let merchant = normalized(entry.title)
            guard merchant.count >= 4 else { continue }
            let key = "\(entry.kind.rawValue):\(merchant)"
            var draft = grouped[key] ?? Draft(title: entry.title, kind: entry.kind,
                                               categoryCounts: [:], entryIDs: [])
            draft.categoryCounts[categoryID, default: 0] += 1
            draft.entryIDs.insert(entry.id)
            grouped[key] = draft
        }
        return grouped.map { item in
            let (key, draft) = item
            return CategoryLearningGroup(id: key, title: draft.title, kind: draft.kind,
                                         exampleCount: draft.entryIDs.count,
                                         categoryCounts: draft.categoryCounts, entryIDs: draft.entryIDs)
        }.sorted {
            if $0.exampleCount != $1.exampleCount { return $0.exampleCount > $1.exampleCount }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func suggestion(for title: String, kind: EntryKind,
                    activeCategories: [LedgerCategory]) -> CategoryMemorySuggestion? {
        let merchant = Self.normalized(title)
        guard merchant.count >= 4 else { return nil }
        let activeIDs = Set(activeCategories.filter { $0.kind == kind && !$0.isArchived }.map(\.id))

        if let history = counts[Key(kind: kind, merchant: merchant)] {
            let eligible = history.filter { activeIDs.contains($0.key) }
            let total = eligible.values.reduce(0, +)
            guard let winner = eligible.max(by: { $0.value < $1.value }),
                  winner.value * 5 >= total * 4,
                  !eligible.contains(where: { $0.key != winner.key && $0.value == winner.value }) else {
                return nil
            }
            return .init(categoryID: winner.key, exampleCount: winner.value, match: .exact)
        }

        // Character trigrams tolerate minor OCR errors and spacing differences. Use the
        // nearest saved descriptor only when it is clearly better than competing labels.
        let nearbyKeys = Self.trigrams(merchant).keys.reduce(into: Set<Key>()) { result, trigram in
            result.formUnion(keysByTrigram[TrigramKey(kind: kind, value: trigram)] ?? [])
        }
        let candidates = nearbyKeys.compactMap { key -> (categoryID: UUID, count: Int, similarity: Double)? in
            guard abs(key.merchant.count - merchant.count) <= max(3, merchant.count / 4),
                  let history = counts[key] else { return nil }
            let similarity = Self.similarity(merchant, key.merchant)
            guard similarity >= 0.84 else { return nil }
            let eligible = history.filter { activeIDs.contains($0.key) }
            let total = eligible.values.reduce(0, +)
            guard let winner = eligible.max(by: { $0.value < $1.value }),
                  winner.value * 5 >= total * 4 else { return nil }
            return (winner.key, winner.value, similarity)
        }.sorted { $0.similarity > $1.similarity }

        guard let best = candidates.first,
              best.similarity >= 0.90 || best.count >= 2 else { return nil }
        if let rival = candidates.first(where: { $0.categoryID != best.categoryID }),
           best.similarity - rival.similarity < 0.12 { return nil }
        return .init(categoryID: best.categoryID, exampleCount: best.count, match: .similar)
    }

    static func normalized(_ raw: String) -> String {
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX"))
        let withoutBranch = folded.replacingOccurrences(
            of: #"\bcol\s*\d{1,2}\b"#, with: " ", options: .regularExpression)
        let letters = withoutBranch.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return letters.map(String.init).joined()
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = trigrams(lhs)
        let right = trigrams(rhs)
        let overlap = left.reduce(0) { $0 + min($1.value, right[$1.key, default: 0]) }
        let total = left.values.reduce(0, +) + right.values.reduce(0, +)
        return total == 0 ? 0 : Double(2 * overlap) / Double(total)
    }

    private static func trigrams(_ value: String) -> [String: Int] {
        let characters = Array(value)
        guard characters.count >= 3 else { return [:] }
        var counts: [String: Int] = [:]
        for start in 0...(characters.count - 3) {
            counts[String(characters[start...start + 2]), default: 0] += 1
        }
        return counts
    }
}
