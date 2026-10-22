import Foundation
import Testing
@testable import LedgerlyDomain

@MainActor
struct CategoryExclusionRestoreTests {
    private let categoryID = UUID()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ title: String, category: String = "Groceries", kind: EntryKind = .expense,
                       id: UUID = UUID(), date: Date? = nil, categoryID: UUID? = nil) -> LedgerEntry {
        .init(id: id, kind: kind, amount: 430, title: title, category: category,
              date: date ?? now, note: "Kept note", categoryID: categoryID ?? self.categoryID)
    }

    @Test func excludedSearchAndKindFiltersDoNotExposeIncludedOrMissingEntries() {
        let tech = entry("Digital TECHLABS", category: "Education")
        let cafe = entry("Café Express")
        let income = entry("Digital Tech Labs", category: "Freelance", kind: .income)
        let included = entry("Digital TECHLABS")
        let all = [tech, cafe, income, included]
        let excluded: Set<UUID> = [tech.id, cafe.id, income.id, UUID()]
        #expect(CategoryLearningReview.excludedExamples(entries: all, excludedEntryIDs: excluded,
            search: " digital tech labs ", kind: .expense).map(\.id) == [tech.id])
        #expect(CategoryLearningReview.excludedExamples(entries: all, excludedEntryIDs: excluded,
            search: "CAFE").map(\.id) == [cafe.id])
        #expect(CategoryLearningReview.excludedExamples(entries: all, excludedEntryIDs: excluded,
            search: "freelance", kind: .income).map(\.id) == [income.id])
        #expect(CategoryLearningReview.excludedExamples(entries: all, excludedEntryIDs: excluded,
            search: "123456").isEmpty)
        #expect(CategoryLearningReview.excludedExamples(entries: all, excludedEntryIDs: excluded,
            search: "!!!").isEmpty)
    }

    @Test func newestFirstWithStableTiesIncludesBlankAndFutureDescriptionsForManagement() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = entry("", id: firstID)
        let second = entry("Example", id: secondID)
        let future = entry("Planned", date: now.addingTimeInterval(60))
        let all = [second, first, future]
        #expect(CategoryLearningReview.excludedExamples(entries: all,
            excludedEntryIDs: Set(all.map(\.id))).map(\.id) == [future.id, firstID, secondID])
    }

    @Test func restoringAFilteredSnapshotKeepsOtherAndDeletedExclusions() {
        let expense = entry("Keells")
        let income = entry("Salary", kind: .income)
        let deletedID = UUID()
        let all = [expense, income]
        let original: Set<UUID> = [expense.id, income.id, deletedID]
        let visible = CategoryLearningReview.excludedExamples(entries: all,
            excludedEntryIDs: original, kind: .expense)
        let restored = CategoryLearningReview.restoringExamples(Set(visible.map(\.id)),
            excludedEntryIDs: original, entries: all)
        #expect(restored == [income.id, deletedID])
        #expect(CategoryLearningReview.restoringExamples([expense.id, deletedID, UUID()],
            excludedEntryIDs: restored, entries: all) == restored)
        #expect(CategoryLearningReview.restoringExamples([], excludedEntryIDs: original, entries: all) == original)
    }

    @Test func restorationReturnsSavedChoiceAndPreservesConflictingCategoryAbstention() {
        let groceryID = UUID()
        let diningID = UUID()
        let categories = [
            LedgerCategory(id: groceryID, name: "Groceries", kind: .expense,
                           isSystem: true, isArchived: false, sortIndex: 0),
            LedgerCategory(id: diningID, name: "Food & Drink", kind: .expense,
                           isSystem: true, isArchived: false, sortIndex: 1)
        ]
        let original = entry("Keells Super", categoryID: groceryID)
        let different = entry("KEELLS SUPER COL07", category: "Food & Drink", categoryID: diningID)
        let excluded: Set<UUID> = [original.id, different.id]
        let entries = [original, different]
        #expect(CategoryMemoryIndex(entries: entries, excludedEntryIDs: excluded)
            .suggestion(for: "Keells Super", kind: .expense, activeCategories: categories) == nil)
        let restored = CategoryLearningReview.restoringExamples([original.id],
            excludedEntryIDs: excluded, entries: entries)
        #expect(CategoryMemoryIndex(entries: entries, excludedEntryIDs: restored)
            .suggestion(for: "Keells Super", kind: .expense, activeCategories: categories)?.categoryID == groceryID)
        let restoredAll = CategoryLearningReview.restoringExamples([different.id],
            excludedEntryIDs: restored, entries: entries)
        #expect(CategoryMemoryIndex(entries: entries, excludedEntryIDs: restoredAll)
            .suggestion(for: "Keells Super", kind: .expense, activeCategories: categories) == nil)
    }
}
