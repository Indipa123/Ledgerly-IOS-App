import Foundation
import Testing
@testable import LedgerlyDomain

@MainActor
struct CategoryHistoryTests {
    private func entry(id: UUID, category: LedgerCategory, amount: Decimal = 100,
                       title: String = "Example", note: String = "") -> LedgerEntry {
        .init(id: id, kind: category.kind, amount: amount, title: title, category: category.name,
              date: .now, note: note, categoryID: category.id)
    }

    @Test func localChangesKeepOrderedNamesAndKindsWithoutInventingFirstSaveEvidence() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        var from = try #require(repository.fetchCategories().first { $0.kind == .expense })
        let to = try #require(repository.fetchCategories().first { $0.kind == .income })
        let id = UUID()
        try repository.upsert(entry(id: id, category: from))
        #expect(try repository.fetchEntries().first?.categoryChanges.isEmpty == true)
        from.name = "Renamed before change"
        try repository.saveCategory(from)
        try repository.upsert(entry(id: id, category: from, amount: 150, title: "Another description", note: "Note"))
        #expect(try repository.fetchEntries().first?.categoryChanges.isEmpty == true)
        try repository.upsert(entry(id: id, category: to))
        try repository.upsert(entry(id: id, category: from))
        let saved = try #require(repository.fetchEntries().first)
        #expect(saved.categorySuggestion == nil)
        #expect(saved.categoryChanges.count == 2)
        #expect(saved.categoryChanges[0].from.name == "Renamed before change")
        #expect(saved.categoryChanges[0].from.kind == 0)
        #expect(saved.categoryChanges[0].to.kind == 1)
        #expect(saved.categoryChanges[1].to.categoryID == from.id)
        #expect(saved.categoryChanges.allSatisfy { $0.origin == .thisDevice })
        #expect(saved.categoryChanges[0].id != saved.categoryChanges[1].id)
        from.name = "Renamed after change"
        try repository.saveCategory(from)
        #expect(try repository.fetchEntries().first?.categoryChanges == saved.categoryChanges)
    }

    @Test func snapshotAndReviewSurviveHistoryWritesAndUndo() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let categories = try repository.fetchCategories().filter { $0.kind == .expense }
        let from = try #require(categories.first)
        let to = try #require(categories.last)
        let id = UUID()
        var original = entry(id: id, category: from)
        original.categorySuggestion = .init(source: nil, suggestedCategoryID: nil,
            suggestedCategoryName: nil, savedCategoryID: from.id, savedCategoryName: from.name,
            kind: 0, recordedAt: .now)
        try repository.upsert(original)
        #expect(try repository.markCategoryReviewed(original))
        let snapshot = try #require(repository.fetchEntries().first?.categorySuggestion)
        try repository.upsert(entry(id: id, category: to))
        let changed = try #require(repository.fetchEntries().first)
        #expect(changed.categorySuggestion == snapshot)
        #expect(changed.categoryChanges.count == 1)
        #expect(CategoryReviewQueue.pending(entries: [changed]).count == 1)
        #expect(try repository.markCategoryReviewed(changed))
        #expect(try repository.fetchEntries().first?.categoryChanges == changed.categoryChanges)
        try repository.softDelete(id: id)
        try repository.restoreDeleted(id: id)
        #expect(try repository.fetchEntries().first?.categoryChanges == changed.categoryChanges)
    }

    @Test func onlyAcceptedLiveCloudCategoryChangesCreateHistory() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let anotherDevice = CoreDataLedgerRepository(inMemory: true)
        let category = try #require(repository.fetchCategories().first { $0.kind == .expense })
        let id = UUID()
        try repository.upsert(entry(id: id, category: category))
        let original = try #require(try repository.syncEntry(id: id))
        let remote = CloudEntry(id: id, kind: .income, amount: 300, title: "Received",
            category: "Salary", date: original.date, note: "", createdAt: original.createdAt,
            updatedAt: original.updatedAt.addingTimeInterval(60), deletedAt: nil)
        try repository.applyRemote(remote)
        try repository.applyRemote(remote)
        try repository.applyRemote(original)
        let changed = try #require(repository.fetchEntries().first)
        #expect(changed.categoryChanges.count == 1)
        #expect(changed.categoryChanges.first?.origin == .cloudUpdate)
        #expect(changed.categoryChanges.first?.to.name == "Salary")
        #expect(changed.categoryChanges.first?.from.categoryID == category.id)
        try anotherDevice.applyRemote(remote)
        #expect(try anotherDevice.fetchEntries().first?.categoryChanges.isEmpty == true)
        let deleted = CloudEntry(id: id, kind: .expense, amount: 300, title: "Received",
            category: "Groceries", date: original.date, note: "", createdAt: original.createdAt,
            updatedAt: remote.updatedAt.addingTimeInterval(60), deletedAt: remote.updatedAt)
        try repository.applyRemote(deleted)
        try repository.restoreDeleted(id: id)
        #expect(try repository.fetchEntries().first?.categoryChanges == changed.categoryChanges)
    }

    @Test func failedCategoryValidationDoesNotAppendHistory() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let category = try #require(repository.fetchCategories().first { $0.kind == .expense })
        let id = UUID()
        try repository.upsert(entry(id: id, category: category))
        var invalid = entry(id: id, category: category)
        invalid.categoryID = UUID()
        #expect(throws: LedgerDataError.self) { try repository.upsert(invalid) }
        let saved = try #require(repository.fetchEntries().first)
        #expect(saved.categoryChanges.isEmpty)
        #expect(saved.categoryID == category.id && saved.amount == 100)
    }

    @Test func previousFlatSnapshotAndVersionedHistoryRoundTrip() throws {
        let categoryID = UUID()
        let previous = CategorySuggestionRecord(source: .personalModel, suggestedCategoryID: categoryID,
            suggestedCategoryName: "Groceries", savedCategoryID: categoryID,
            savedCategoryName: "Groceries", kind: 0, recordedAt: .now, modelVersion: UUID())
        var metadata = try CategoryHistoryMetadata.decode(JSONEncoder().encode(previous))
        #expect(metadata.firstSave == previous && metadata.changes.isEmpty)
        metadata.recordChange(from: .init(categoryID: categoryID, name: "Groceries", kind: 0),
            to: .init(categoryID: UUID(), name: "Salary", kind: 1), origin: .thisDevice)
        #expect(try CategoryHistoryMetadata.decode(JSONEncoder().encode(metadata)) == metadata)
        #expect(try CategoryHistoryMetadata.decode(nil) == .init())
        #expect(throws: DecodingError.self) {
            try CategoryHistoryMetadata.decode(Data("{\"version\":99,\"changes\":[]}".utf8))
        }
        #expect(throws: DecodingError.self) { try CategoryHistoryMetadata.decode(Data("broken".utf8)) }
    }
}
