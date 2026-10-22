import Foundation
import NaturalLanguage

/// Generic, bundled suggestions for descriptions that the user's saved choices do not cover.
/// The model never reads or trains on private transactions.
final class SeedCategoryModel {
    private let model: NLModel?

    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "SeedCategoryClassifier", withExtension: "mlmodelc") else {
            model = nil
            return
        }
        model = try? NLModel(contentsOf: url)
    }

    func suggestion(for title: String, kind: EntryKind,
                    activeCategories: [LedgerCategory]) -> CategoryMemorySuggestion? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.rangeOfCharacter(from: .letters) != nil,
              CategorySuggestionPolicy.hasDistinctiveDescription(trimmed),
              let model else { return nil }

        let prefix = kind == .expense ? "expense" : "income"
        let ranked = model.predictedLabelHypotheses(for: "\(prefix) \(trimmed.lowercased())", maximumCount: 2)
            .sorted { $0.value > $1.value }
        guard let best = ranked.first,
              CategorySuggestionPolicy.accepts(kindPrefix: prefix, title: trimmed, label: best.key,
                                               confidence: best.value,
                                               secondConfidence: ranked.dropFirst().first?.value ?? 0)
        else { return nil }

        let name = String(best.key.dropFirst(prefix.count + 1))
        guard let category = activeCategories.first(where: {
            $0.kind == kind && !$0.isArchived &&
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { return nil }
        return .init(categoryID: category.id, exampleCount: 0, match: .model)
    }

    func assistance(for title: String, kind: EntryKind,
                    activeCategories: [LedgerCategory]) -> CategoryAssistance {
        if let reliable = suggestion(for: title, kind: kind, activeCategories: activeCategories) {
            return .init(suggestion: reliable)
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, CategorySuggestionPolicy.hasDistinctiveDescription(trimmed),
              let model else { return .init() }
        let prefix = kind == .expense ? "expense" : "income"
        let scores = model.predictedLabelHypotheses(for: "\(prefix) \(trimmed.lowercased())", maximumCount: 20)
            .map { CategoryRankedScore(label: $0.key, score: $0.value) }
        return .init(alternatives: CategorySuggestionPolicy.alternatives(scores: scores,
            title: title, kind: kind, activeCategories: activeCategories, source: .model))
    }
}
