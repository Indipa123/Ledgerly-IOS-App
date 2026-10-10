import Foundation

struct CategoryEvaluationReport {
    let trainingCount: Int
    let testCount: Int
    let suggestedCount: Int
    let correctCount: Int
    let exactBaselineSuggestedCount: Int
    let exactBaselineCorrectCount: Int
    let majorityBaselineCorrectCount: Int
    let unseenDescriptionCount: Int
    let unseenSuggestedCount: Int
    let unseenCorrectCount: Int

    var coverage: Double { Double(suggestedCount) / Double(testCount) }
    var accuracyWhenSuggested: Double? {
        suggestedCount == 0 ? nil : Double(correctCount) / Double(suggestedCount)
    }
    var exactBaselineCoverage: Double { Double(exactBaselineSuggestedCount) / Double(testCount) }
    var exactBaselineAccuracy: Double? {
        exactBaselineSuggestedCount == 0 ? nil : Double(exactBaselineCorrectCount) / Double(exactBaselineSuggestedCount)
    }
    var majorityBaselineAccuracy: Double { Double(majorityBaselineCorrectCount) / Double(testCount) }
}

enum CategoryEvaluation {
    /// A retrospective, time-ordered holdout. Newer labels are never used to train the predictor.
    static func evaluate(entries: [LedgerEntry], activeCategories: [LedgerCategory],
                         excludedEntryIDs: Set<UUID> = [], asOf: Date = .now) -> CategoryEvaluationReport? {
        let eligibleIDs = Set(activeCategories.filter { !$0.isArchived }.map(\.id))
        let labeled = entries.filter {
            $0.date <= asOf && !excludedEntryIDs.contains($0.id) &&
            $0.categoryID.map(eligibleIDs.contains) == true &&
            CategoryMemoryIndex.normalized($0.title).count >= 4
        }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard labeled.count >= 10 else { return nil }
        let split = max(1, labeled.count * 4 / 5)
        let training = Array(labeled[..<split])
        let test = labeled[split...]
        let index = CategoryMemoryIndex(entries: training)

        struct DescriptorKey: Hashable {
            let kind: EntryKind
            let merchant: String
        }
        var exactCounts: [DescriptorKey: [UUID: Int]] = [:]
        var majorityCounts: [EntryKind: [UUID: Int]] = [:]
        for entry in training {
            guard let categoryID = entry.categoryID else { continue }
            let key = DescriptorKey(kind: entry.kind, merchant: CategoryMemoryIndex.normalized(entry.title))
            exactCounts[key, default: [:]][categoryID, default: 0] += 1
            majorityCounts[entry.kind, default: [:]][categoryID, default: 0] += 1
        }

        var suggested = 0
        var correct = 0
        var exactSuggested = 0
        var exactCorrect = 0
        var majorityCorrect = 0
        var unseen = 0
        var unseenSuggested = 0
        var unseenCorrect = 0

        for entry in test {
            let key = DescriptorKey(kind: entry.kind, merchant: CategoryMemoryIndex.normalized(entry.title))
            let isUnseen = exactCounts[key] == nil
            if isUnseen { unseen += 1 }
            if let prediction = index.suggestion(for: entry.title, kind: entry.kind,
                                                 activeCategories: activeCategories) {
                suggested += 1
                if prediction.categoryID == entry.categoryID { correct += 1 }
                if isUnseen {
                    unseenSuggested += 1
                    if prediction.categoryID == entry.categoryID { unseenCorrect += 1 }
                }
            }
            if let counts = exactCounts[key], let winner = mostFrequent(in: counts) {
                exactSuggested += 1
                if winner == entry.categoryID { exactCorrect += 1 }
            }
            if let counts = majorityCounts[entry.kind],
               mostFrequent(in: counts) == entry.categoryID { majorityCorrect += 1 }
        }
        return CategoryEvaluationReport(
            trainingCount: training.count, testCount: test.count,
            suggestedCount: suggested, correctCount: correct,
            exactBaselineSuggestedCount: exactSuggested,
            exactBaselineCorrectCount: exactCorrect,
            majorityBaselineCorrectCount: majorityCorrect,
            unseenDescriptionCount: unseen,
            unseenSuggestedCount: unseenSuggested,
            unseenCorrectCount: unseenCorrect
        )
    }

    private static func mostFrequent(in counts: [UUID: Int]) -> UUID? {
        counts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key.uuidString < $1.key.uuidString
        }.first?.key
    }
}
