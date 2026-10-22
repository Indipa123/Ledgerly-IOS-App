import Foundation
import Testing
@testable import LedgerlyDomain

@MainActor
struct CategoryPredictionHistoryTests {
    private func outcome(_ name: String? = nil, id: UUID? = nil,
                         source: CategoryMatch? = nil, kind: Int16 = 0,
                         alternatives: [CategoryAlternative] = [], version: UUID? = nil) -> CategoryPredictionOutcome {
        .init(kind: kind, source: source, suggestedCategoryID: id,
              suggestedCategoryName: name, modelVersion: version, alternatives: alternatives)
    }

    @Test func repeatedOutcomeIsCollapsedButReturnsTypeSourceAndModelChangesRemain() {
        let id = UUID(), version = UUID()
        let reliable = outcome("Food", id: id, source: .model)
        var history = CategoryPredictionHistory()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        history.append(reliable, at: start)
        history.append(reliable, at: start.addingTimeInterval(1))
        #expect(history.events.count == 1)
        #expect(history.events.first?.recordedAt == start)
        history.append(outcome(), at: start.addingTimeInterval(2))
        history.append(reliable, at: start.addingTimeInterval(3))
        history.append(outcome("Food", id: id, source: .personalModel, version: version))
        history.append(outcome("Food", id: id, source: .personalModel, kind: 1, version: version))
        #expect(history.events.count == 5)
        #expect(history.events[2].outcome == reliable)
        #expect(history.events[3].outcome.modelVersion == version)
        #expect(history.events[4].outcome.kind == 1)
        #expect(Set(history.events.map(\.id)).count == 5)
    }

    @Test func longEditingSessionKeepsLatestTwentyAndCountsOmissions() {
        var history = CategoryPredictionHistory()
        for index in 0..<28 {
            history.append(outcome("Category \(index)", id: UUID(), source: .model),
                           at: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(history.events.count == 20)
        #expect(history.omittedCount == 8)
        #expect(history.events.first?.outcome.suggestedCategoryName == "Category 8")
        #expect(history.events.last?.outcome.suggestedCategoryName == "Category 27")
        history.append(history.events.last!.outcome)
        #expect(history.omittedCount == 8)
    }

    @Test func uncertainAlternativesRoundTripAndLegacyRecordHasNoInventedHistory() throws {
        let id = UUID(), version = UUID()
        let options = [CategoryAlternative(categoryID: id, name: "Education",
                                           source: .personalModel, modelVersion: version)]
        var history = CategoryPredictionHistory()
        history.append(outcome(alternatives: options))
        history.append(outcome(alternatives: options))
        #expect(history.events.count == 1)
        let record = CategorySuggestionRecord(source: nil, suggestedCategoryID: nil,
            suggestedCategoryName: nil, savedCategoryID: id, savedCategoryName: "Education",
            kind: 0, recordedAt: .now, alternatives: options, predictionHistory: history)
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(CategorySuggestionRecord.self, from: encoded)
        #expect(decoded == record)
        #expect(decoded.wasAccepted == nil)
        #expect(decoded.predictionHistory?.events.first?.outcome.alternatives == options)
        let legacy = Data("""
        {"savedCategoryID":"\(id)","savedCategoryName":"Education","kind":0,"recordedAt":100}
        """.utf8)
        #expect(try JSONDecoder().decode(CategorySuggestionRecord.self, from: legacy).predictionHistory == nil)
        let keys = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(history.events[0].outcome)) as? [String: Any])
        #expect(Set(keys.keys).isSubset(of: ["kind", "source", "suggestedCategoryID", "suggestedCategoryName", "modelVersion", "alternatives"]))
    }

    @Test func historySurvivesEditsAndUndoAndDoesNotSyncToAnotherLedger() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let category = try #require(repository.fetchCategories().first { $0.kind == .expense })
        var history = CategoryPredictionHistory()
        history.append(outcome())
        history.append(outcome(category.name, id: category.id, source: .model))
        let record = CategorySuggestionRecord(source: .model, suggestedCategoryID: category.id,
            suggestedCategoryName: category.name, savedCategoryID: category.id, savedCategoryName: category.name,
            kind: 0, recordedAt: .now, predictionHistory: history)
        var entry = LedgerEntry(id: UUID(), kind: .expense, amount: 430, title: "Bus ticket",
            category: category.name, date: .now, note: "", categoryID: category.id, categorySuggestion: record)
        try repository.upsert(entry)
        entry.categorySuggestion = nil
        try repository.upsert(entry)
        try repository.softDelete(id: entry.id)
        try repository.restoreDeleted(id: entry.id)
        let saved = try #require(repository.fetchEntries().first)
        #expect(saved.categorySuggestion == record)
        #expect(saved.amount == 430)
        let otherDevice = CoreDataLedgerRepository(inMemory: true)
        let upload = try #require(try repository.syncEntry(id: entry.id))
        try otherDevice.applyRemote(upload)
        #expect(try otherDevice.fetchEntries().first?.categorySuggestion == nil)
    }
}
