import Foundation
import Testing
@testable import LedgerlyDomain

struct CategoryLearningReviewTests {
    private let groceryID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let diningID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func entry(_ title: String, categoryID: UUID, kind: EntryKind = .expense,
                       day: Int = 0, id: UUID = UUID()) -> LedgerEntry {
        .init(id: id, kind: kind, amount: 100, title: title, category: "Saved category",
              date: Date(timeIntervalSince1970: Double(1_700_000_000 + day * 86_400)),
              note: "Kept note", categoryID: categoryID)
    }

    @Test func mixedDescriptionsComeFirstAndIncomeIsSeparate() throws {
        let entries = [
            entry("Keells Super", categoryID: groceryID),
            entry("KEELLS SUPER COL07 *4412", categoryID: diningID),
            entry("Keells Super", categoryID: groceryID, kind: .income)
        ] + (0..<5).map { _ in entry("Barista", categoryID: diningID) }
        let groups = CategoryMemoryIndex.groups(entries: entries)
        let reviewed = CategoryLearningReview.groups(groups)
        #expect(reviewed.count == 3)
        let mixed = try #require(reviewed.first)
        #expect(mixed.hasMixedCategories)
        #expect(mixed.kind == .expense)
        #expect(mixed.exampleCount == 2)
        #expect(CategoryLearningReview.groups(groups, mixedOnly: true).map(\.id) == [mixed.id])
        #expect(groups.first(where: { $0.kind == .income })?.hasMixedCategories == false)
    }

    @Test func searchToleratesSpacesAndAccentsWithoutMatchingEveryNumericQuery() {
        let groups = CategoryMemoryIndex.groups(entries: [
            entry("Digital TECHLABS", categoryID: groceryID),
            entry("Café Express", categoryID: diningID)
        ])
        #expect(CategoryLearningReview.groups(groups, search: " digital tech labs ").count == 1)
        #expect(CategoryLearningReview.groups(groups, search: "CAFE").first?.title == "Café Express")
        #expect(CategoryLearningReview.groups(groups, search: "123456").isEmpty)
        #expect(CategoryLearningReview.groups(groups, search: "!!!").isEmpty)
    }

    @Test func examplesAreNewestFirstWithStableTiesAndNoForgottenOrUnrelatedEntries() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let older = entry("Keells Super", categoryID: groceryID, day: 1)
        let newer = entry("Keells Super", categoryID: diningID, day: 2, id: secondID)
        let tied = entry("KEELLS SUPER", categoryID: groceryID, day: 2, id: firstID)
        let forgotten = entry("Keells Super", categoryID: diningID, day: 3)
        let unrelated = entry("Barista", categoryID: diningID, day: 4)
        let entries = [newer, older, unrelated, tied, forgotten]
        let group = try #require(CategoryMemoryIndex.groups(entries: entries,
            excludedEntryIDs: [forgotten.id]).first(where: { $0.entryIDs.contains(older.id) }))
        #expect(CategoryLearningReview.examples(in: group, entries: entries).map(\.id) == [firstID, secondID, older.id])
    }

    @Test @MainActor func correctingOrExcludingOneExampleUpdatesLearningAndKeepsLedgerData() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let categories = try repository.fetchCategories().filter { $0.kind == .expense && !$0.isArchived }
        let groceries = try #require(categories.first)
        let dining = try #require(categories.dropFirst().first)
        let original = entry("Keells Super", categoryID: groceries.id)
        var changed = entry("KEELLS SUPER COL07", categoryID: dining.id, day: 1)
        try repository.upsert(original)
        try repository.upsert(changed)
        let before = try repository.fetchEntries()
        #expect(CategoryLearningReview.groups(CategoryMemoryIndex.groups(entries: before), mixedOnly: true).count == 1)
        let excluding = CategoryMemoryIndex(entries: before, excludedEntryIDs: [changed.id])
        #expect(excluding.suggestion(for: "Keells Super", kind: .expense,
            activeCategories: categories)?.categoryID == groceries.id)
        #expect(try repository.fetchEntries().count == 2)
        #expect(try repository.fetchEntries().first(where: { $0.id == changed.id })?.categoryID == dining.id)

        // The existing transaction editor saves this change through the repository.
        changed = entry(changed.title, categoryID: groceries.id, day: 1, id: changed.id)
        try repository.upsert(changed)
        let after = try repository.fetchEntries()
        #expect(CategoryLearningReview.groups(CategoryMemoryIndex.groups(entries: after), mixedOnly: true).isEmpty)
        #expect(CategoryMemoryIndex(entries: after).suggestion(for: "Keells Super", kind: .expense,
            activeCategories: categories)?.categoryID == groceries.id)
        #expect(after.reduce(Decimal.zero) { $0 + $1.amount } == 200)
        #expect(after.first(where: { $0.id == changed.id })?.note == "Kept note")

        // Changing the description moves it to its current group; the old group must not retain it.
        changed = entry("Barista", categoryID: groceries.id, day: 1, id: changed.id)
        try repository.upsert(changed)
        let regrouped = CategoryMemoryIndex.groups(entries: try repository.fetchEntries())
        let oldGroup = try #require(regrouped.first(where: { $0.entryIDs.contains(original.id) }))
        #expect(oldGroup.entryIDs == [original.id])
    }
}
