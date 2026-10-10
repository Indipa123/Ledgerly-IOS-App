import Foundation

enum CategoryMatch: Equatable {
    case exact
    case similar
}

struct CategoryMemorySuggestion: Equatable {
    let categoryID: UUID
    let exampleCount: Int
    let match: CategoryMatch
}

struct CategoryLearningGroup: Identifiable {
    let id: String
    let title: String
    let kind: EntryKind
    let exampleCount: Int
    let categoryCounts: [UUID: Int]
    let entryIDs: Set<UUID>
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
