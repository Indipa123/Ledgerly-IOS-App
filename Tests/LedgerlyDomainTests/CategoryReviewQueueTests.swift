import Foundation
import Testing
@testable import LedgerlyDomain

@MainActor
struct CategoryReviewQueueTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let categoryID = UUID()

    private func entry(_ title: String = "Unfamiliar shop", kind: EntryKind = .expense,
                       date: Date? = nil, hasRecord: Bool = true,
                       source: CategoryMatch? = nil, id: UUID = UUID()) -> LedgerEntry {
        .init(id: id, kind: kind, amount: 100, title: title, category: "Saved category",
              date: date ?? now, note: "Keep this note", categoryID: categoryID,
              categorySuggestion: hasRecord ? .init(source: source,
                suggestedCategoryID: source == nil ? nil : categoryID,
                suggestedCategoryName: source == nil ? nil : "Saved category",
                savedCategoryID: categoryID, savedCategoryName: "Saved category",
                kind: kind.rawValue, recordedAt: now) : nil)
    }

    @Test func onlyRecordedAbstentionsWithDescriptionsAreQueued() {
        let expense = entry()
        let income = entry("New client", kind: .income)
        let legacy = entry(hasRecord: false)
        let known = entry(source: .exact)
        let excluded = entry()
        let future = entry(date: now.addingTimeInterval(1))
        let queued = CategoryReviewQueue.pending(entries: [legacy, known, entry("  "),
            future, expense, income, excluded], excludedEntryIDs: [excluded.id], asOf: now)
        #expect(Set(queued.map(\.id)) == [expense.id, income.id])
        #expect(expense.categorySuggestion?.wasAccepted == nil)
    }

    @Test func newestFirstWithStableTieOrder() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let lastID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let old = entry(date: now.addingTimeInterval(-1))
        let a = entry(id: firstID)
        let b = entry(id: lastID)
        #expect(CategoryReviewQueue.pending(entries: [b, old, a], asOf: now).map(\.id) == [a.id, b.id, old.id])
    }

    @Test func reviewMatchesCategoryIdentityAndTypeButNotChangedDescription() {
        var original = entry()
        let title = original.title
        original.categorySuggestion?.review = .init(categoryID: categoryID, kind: 0,
                                                     title: title, reviewedAt: now)
        #expect(CategoryReviewQueue.pending(entries: [original], asOf: now).isEmpty)
        var changedCategory = original
        changedCategory.categoryID = UUID()
        #expect(CategoryReviewQueue.pending(entries: [changedCategory], asOf: now).count == 1)
        let reviewed = original.categorySuggestion?.review
        #expect(reviewed?.matches(categoryID: categoryID, kind: 1, title: original.title) == false)
        #expect(reviewed?.matches(categoryID: categoryID, kind: 0, title: "Another shop") == false)
    }

    @Test func previousSuggestionJSONDecodesWithoutInventingReviewState() throws {
        let json = """
        {"source":"exact","suggestedCategoryID":"\(categoryID)",
         "suggestedCategoryName":"Groceries","savedCategoryID":"\(categoryID)",
         "savedCategoryName":"Groceries","kind":0,"recordedAt":100}
        """
        let record = try JSONDecoder().decode(CategorySuggestionRecord.self, from: Data(json.utf8))
        #expect(record.source == .exact)
        #expect(record.wasAccepted == true)
        #expect(record.review == nil)
        let manual = try #require(entry().categorySuggestion)
        #expect(try JSONDecoder().decode(CategorySuggestionRecord.self,
                                        from: JSONEncoder().encode(manual)) == manual)
    }

    @Test func markingReviewedPersistsLocallyWithoutFinancialOrCloudChanges() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let category = try #require(repository.fetchCategories().first { $0.kind == .expense })
        var item = entry()
        item.categoryID = category.id
        try repository.upsert(item)
        let before = try #require(try repository.syncEntry(id: item.id))
        #expect(try repository.markCategoryReviewed(item))
        let saved = try #require(repository.fetchEntries().first)
        #expect(CategoryReviewQueue.pending(entries: [saved], asOf: now).isEmpty)
        #expect(saved.amount == item.amount && saved.note == item.note && saved.categoryID == item.categoryID)
        #expect(saved.categorySuggestion?.recordedAt == item.categorySuggestion?.recordedAt)
        let after = try #require(try repository.syncEntry(id: item.id))
        #expect(after.updatedAt == before.updatedAt)
        let otherDevice = CoreDataLedgerRepository(inMemory: true)
        try otherDevice.applyRemote(after)
        #expect(try otherDevice.fetchEntries().first?.categorySuggestion == nil)
        try repository.softDelete(id: item.id)
        try repository.restoreDeleted(id: item.id)
        #expect(try repository.fetchEntries().first?.categorySuggestion?.review == saved.categorySuggestion?.review)
        var renamed = category
        renamed.name = "Renamed category"
        try repository.saveCategory(renamed)
        #expect(CategoryReviewQueue.pending(entries: try repository.fetchEntries(), asOf: now).isEmpty)
        let another = try #require(repository.fetchCategories().first { $0.kind == .expense && $0.id != category.id })
        let changed = LedgerEntry(id: item.id, kind: item.kind, amount: item.amount,
                                  title: item.title, category: another.name, date: item.date,
                                  note: item.note, categoryID: another.id)
        try repository.upsert(changed)
        #expect(CategoryReviewQueue.pending(entries: try repository.fetchEntries(), asOf: now).count == 1)
        #expect(try !repository.markCategoryReviewed(item))
        #expect(try repository.markCategoryReviewed(changed))
        #expect(CategoryReviewQueue.pending(entries: try repository.fetchEntries(), asOf: now).isEmpty)
    }

    @Test func staleDeletedAndUnknownEntriesCannotBeMarkedReviewed() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let category = try #require(repository.fetchCategories().first { $0.kind == .expense })
        var stale = entry()
        stale.categoryID = category.id
        try repository.upsert(stale)
        var changed = entry("Changed remotely", id: stale.id)
        changed.categoryID = category.id
        try repository.upsert(changed)
        #expect(try !repository.markCategoryReviewed(stale))
        #expect(try repository.fetchEntries().first?.categorySuggestion?.review == nil)
        try repository.softDelete(id: stale.id)
        #expect(try !repository.markCategoryReviewed(changed))
        var unknown = entry(hasRecord: false)
        unknown.categoryID = category.id
        try repository.upsert(unknown)
        #expect(try !repository.markCategoryReviewed(unknown))
        var suggested = entry(source: .model)
        suggested.categoryID = category.id
        try repository.upsert(suggested)
        #expect(try !repository.markCategoryReviewed(suggested))
    }
}
