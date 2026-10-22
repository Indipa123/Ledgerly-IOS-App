import Foundation
import Testing
@testable import LedgerlyDomain

@MainActor
struct CategoryAlternativeTests {
    private func category(_ name: String, kind: EntryKind = .expense, archived: Bool = false,
                          id: UUID = UUID()) -> LedgerCategory {
        .init(id: id, name: name, kind: kind, isSystem: true, isArchived: archived, sortIndex: 0)
    }

    @Test func genericAlternativesRankDeduplicateLimitAndFilterInactiveWrongKindAndInvalidScores() {
        let categories = [category("Groceries"), category("Food"), category("Transport"),
                          category("Shopping"), category("Archived", archived: true), category("Salary", kind: .income)]
        let scores: [CategoryRankedScore] = [
            .init(label: "expense|Shopping", score: 0.10), .init(label: "expense|Food", score: 0.25),
            .init(label: "expense|Groceries", score: 0.20), .init(label: "expense|Transport", score: 0.15),
            .init(label: "expense|Food", score: 0.12), .init(label: "expense|Archived", score: 0.9),
            .init(label: "income|Salary", score: 0.95), .init(label: "expense|Missing", score: 0.8),
            .init(label: "expense|Groceries", score: .nan), .init(label: "expense|Groceries", score: .infinity),
            .init(label: "expense|Shopping", score: -1), .init(label: "expense|Shopping", score: 1.01)
        ]
        let options = CategorySuggestionPolicy.alternatives(scores: scores, title: "Unfamiliar merchant",
            kind: .expense, activeCategories: categories, source: .model)
        #expect(options.map(\.name) == ["Food", "Groceries", "Transport"])
        #expect(Set(options.map(\.id)).count == 3)
        #expect(options.allSatisfy { $0.source == .model })
    }

    @Test func personalAlternativesNeedRelevantDescriptionsAndPreserveModelVersion() {
        let near = category("Education")
        let far = category("Transport")
        let income = category("Freelance", kind: .income)
        let version = UUID()
        let scores: [CategoryRankedScore] = [
            .init(label: near.id.uuidString, score: 0.6, similarity: 0.8),
            .init(label: far.id.uuidString, score: 0.9, similarity: 0.2),
            .init(label: income.id.uuidString, score: 1, similarity: 1),
            .init(label: "bad-label", score: 1, similarity: 1)
        ]
        let options = CategorySuggestionPolicy.alternatives(scores: scores, title: "Digital school",
            kind: .expense, activeCategories: [near, far, income], source: .personalModel, modelVersion: version)
        #expect(options.map(\.id) == [near.id])
        #expect(options.first?.modelVersion == version)
        for title in ["", " ", "123456", "Bank transfer received", "Bus"] {
            #expect(CategorySuggestionPolicy.alternatives(scores: scores, title: title,
                kind: .expense, activeCategories: [near], source: .personalModel).isEmpty)
        }
    }

    @Test func tiesAreStableAndAlternativesDoNotBypassReliableSuggestionChecks() {
        let first = category("Food", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let second = category("Groceries", id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let scores = [CategoryRankedScore(label: "expense|Groceries", score: 0.2),
                      CategoryRankedScore(label: "expense|Food", score: 0.2)]
        let options = CategorySuggestionPolicy.alternatives(scores: scores, title: "Unfamiliar merchant",
            kind: .expense, activeCategories: [second, first], source: .model)
        #expect(options.map(\.id) == [first.id, second.id])
        #expect(!CategorySuggestionPolicy.accepts(kindPrefix: "expense", title: "Unfamiliar merchant",
            label: "expense|Food", confidence: 0.2, secondConfidence: 0.2))
        #expect(CategoryAssistance(alternatives: options).suggestion == nil)
    }

    @Test func selectingUncertainAlternativeStaysManualAndPersistsWithoutCorrectionWeight() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let chosen = try #require(repository.fetchCategories().first { $0.kind == .expense })
        let alternatives = [CategoryAlternative(categoryID: chosen.id, name: chosen.name,
                                                source: .personalModel, modelVersion: UUID())]
        let record = CategorySuggestionRecord(source: nil, suggestedCategoryID: nil,
            suggestedCategoryName: nil, savedCategoryID: chosen.id, savedCategoryName: chosen.name,
            kind: 0, recordedAt: .now, alternatives: alternatives)
        let entry = LedgerEntry(id: UUID(), kind: .expense, amount: 430, title: "Unfamiliar merchant",
            category: chosen.name, date: .now, note: "", categoryID: chosen.id, categorySuggestion: record)
        try repository.upsert(entry)
        let saved = try #require(repository.fetchEntries().first)
        #expect(saved.categorySuggestion?.alternatives == alternatives)
        #expect(saved.categorySuggestion?.wasAccepted == nil)
        #expect(CategoryCorrectionPolicy.date(for: saved) == nil)
        #expect(CategoryReviewQueue.pending(entries: [saved]).count == 1)
        let oldJSON = """
        {"savedCategoryID":"\(chosen.id)","savedCategoryName":"Groceries","kind":0,"recordedAt":100}
        """
        #expect(try JSONDecoder().decode(CategorySuggestionRecord.self, from: Data(oldJSON.utf8)).alternatives == nil)
    }
}
