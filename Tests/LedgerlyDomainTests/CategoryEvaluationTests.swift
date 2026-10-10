import Foundation
import Testing
@testable import LedgerlyDomain

struct CategoryEvaluationTests {
    private let groceries = LedgerCategory(id: UUID(), name: "Groceries", kind: .expense,
                                           isSystem: true, isArchived: false, sortIndex: 0)
    private let transport = LedgerCategory(id: UUID(), name: "Transport", kind: .expense,
                                           isSystem: true, isArchived: false, sortIndex: 1)
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func reportsAccuracyAtCoverageAgainstBaselines() {
        let training = (0..<8).map { index in
            entry(index < 4 ? "Keells Supermarket" : "Bus Depot",
                  category: index < 4 ? groceries : transport, day: index)
        }
        let entries = training + [
            entry("Keells Supermarket", category: groceries, day: 8),
            entry("Digital Tech Labs", category: transport, day: 9)
        ]
        let report = CategoryEvaluation.evaluate(entries: entries,
                                                 activeCategories: [groceries, transport],
                                                 asOf: start.addingTimeInterval(20 * 86_400))
        #expect(report?.trainingCount == 8)
        #expect(report?.testCount == 2)
        #expect(report?.suggestedCount == 1)
        #expect(report?.correctCount == 1)
        #expect(report?.coverage == 0.5)
        #expect(report?.accuracyWhenSuggested == 1)
        #expect(report?.exactBaselineSuggestedCount == 1)
        #expect(report?.exactBaselineCorrectCount == 1)
        #expect(report?.majorityBaselineCorrectCount == 1)
        #expect(report?.unseenDescriptionCount == 1)
        #expect(report?.unseenSuggestedCount == 0)
    }

    @Test func newerLabelsNeverTrainTheHoldoutPredictor() {
        let entries = (0..<8).map { entry("Keells Supermarket", category: groceries, day: $0) } + [
            entry("Digital Tech Labs", category: transport, day: 8),
            entry("Digital Tech Labs", category: transport, day: 9)
        ]
        let report = CategoryEvaluation.evaluate(entries: entries,
                                                 activeCategories: [groceries, transport],
                                                 asOf: start.addingTimeInterval(20 * 86_400))
        #expect(report?.suggestedCount == 0)
        #expect(report?.exactBaselineSuggestedCount == 0)
        #expect(report?.unseenDescriptionCount == 2)
    }

    @Test func doesNotShowAccuracyForTooFewExamplesOrForgottenHistory() {
        let entries = (0..<10).map { entry("Keells Supermarket", category: groceries, day: $0) }
        let asOf = start.addingTimeInterval(20 * 86_400)
        #expect(CategoryEvaluation.evaluate(entries: Array(entries.prefix(9)),
                                            activeCategories: [groceries], asOf: asOf)?.testCount == nil)
        #expect(CategoryEvaluation.evaluate(entries: entries, activeCategories: [groceries],
                                            excludedEntryIDs: [entries[0].id], asOf: asOf)?.testCount == nil)
    }

    private func entry(_ title: String, category: LedgerCategory, day: Int) -> LedgerEntry {
        LedgerEntry(id: UUID(), kind: category.kind, amount: 100, title: title,
                    category: category.name, date: start.addingTimeInterval(Double(day) * 86_400),
                    note: "", categoryID: category.id)
    }
}
