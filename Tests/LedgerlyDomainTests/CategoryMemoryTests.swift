import Foundation
import Testing
@testable import LedgerlyDomain

struct CategoryMemoryTests {
    private let groceries = LedgerCategory(id: UUID(), name: "Groceries", kind: .expense,
                                           isSystem: true, isArchived: false, sortIndex: 0)
    private let transport = LedgerCategory(id: UUID(), name: "Transport", kind: .expense,
                                           isSystem: true, isArchived: false, sortIndex: 1)

    @Test func normalizesBranchCodesSpacingAndCardNumbers() {
        #expect(CategoryMemoryIndex.normalized("KEELLS SUPER COL07 *4412") ==
                CategoryMemoryIndex.normalized("Keells Super"))
        #expect(CategoryMemoryIndex.normalized("Digital TECHLABS") ==
                CategoryMemoryIndex.normalized("Digital Tech Labs"))
        #expect(CategoryMemoryIndex.normalized("  ").isEmpty)
    }

    @Test func remembersConfirmedCategoryAndAbstainsOnConflicts() {
        let one = entry("Keells Super", category: groceries)
        let index = CategoryMemoryIndex(entries: [one])
        #expect(index.suggestion(for: "KEELLS SUPER COL07 *4412", kind: .expense,
                                  activeCategories: [groceries, transport])?.categoryID == groceries.id)
        #expect(index.suggestion(for: "New merchant", kind: .expense,
                                  activeCategories: [groceries, transport]) == nil)

        let conflicting = CategoryMemoryIndex(entries: [one, entry("Keells Super", category: transport)])
        #expect(conflicting.suggestion(for: "Keells Super", kind: .expense,
                                       activeCategories: [groceries, transport]) == nil)
    }

    @Test func archivedAndWrongKindCategoriesAreNotSuggested() {
        let index = CategoryMemoryIndex(entries: [entry("Keells Super", category: groceries)])
        var archived = groceries
        archived.isArchived = true
        #expect(index.suggestion(for: "Keells Super", kind: .expense,
                                  activeCategories: [archived, transport]) == nil)
        #expect(index.suggestion(for: "Keells Super", kind: .income,
                                  activeCategories: [groceries]) == nil)
    }

    @Test func suggestsAConfirmedCategoryForMinorReceiptTextErrors() {
        let index = CategoryMemoryIndex(entries: [
            entry("Keells Supermarket", category: groceries),
            entry("Keells Supermarket", category: groceries)
        ])
        let result = index.suggestion(for: "Keels Supermarket", kind: .expense,
                                      activeCategories: [groceries, transport])
        #expect(result?.categoryID == groceries.id)
        #expect(result?.match == .similar)
        #expect(result?.exampleCount == 2)
    }

    @Test func doesNotGuessForShortOrUnrelatedDescriptions() {
        let index = CategoryMemoryIndex(entries: [entry("Keells Supermarket", category: groceries)])
        #expect(index.suggestion(for: "Bus", kind: .expense,
                                  activeCategories: [groceries, transport]) == nil)
        #expect(index.suggestion(for: "Digital Tech Labs", kind: .expense,
                                  activeCategories: [groceries, transport]) == nil)
    }

    @Test func aCorrectionChangesFutureExactMatches() {
        let index = CategoryMemoryIndex(entries: [
            entry("Keells Supermarket", category: groceries),
            entry("Keells Supermarket", category: transport)
        ])
        #expect(index.suggestion(for: "Keells Supermarket", kind: .expense,
                                  activeCategories: [groceries, transport]) == nil)
        let corrected = CategoryMemoryIndex(entries: [
            entry("Keells Supermarket", category: groceries),
            entry("Keells Supermarket", category: groceries),
            entry("Keells Supermarket", category: groceries),
            entry("Keells Supermarket", category: groceries),
            entry("Keells Supermarket", category: transport)
        ])
        #expect(corrected.suggestion(for: "Keells Supermarket", kind: .expense,
                                      activeCategories: [groceries, transport])?.categoryID == groceries.id)
    }

    @Test func forgettingExamplesKeepsTransactionsButStopsSuggestions() {
        let saved = entry("Keells Supermarket", category: groceries)
        let groups = CategoryMemoryIndex.groups(entries: [saved])
        #expect(groups.count == 1)
        #expect(groups.first?.entryIDs == Set([saved.id]))

        let forgotten = CategoryMemoryIndex(entries: [saved], excludedEntryIDs: [saved.id])
        #expect(forgotten.suggestion(for: "Keells Supermarket", kind: .expense,
                                     activeCategories: [groceries, transport]) == nil)
        #expect(CategoryMemoryIndex.groups(entries: [saved], excludedEntryIDs: [saved.id]).isEmpty)

        let newTransaction = entry("Keells Supermarket", category: groceries)
        let relearned = CategoryMemoryIndex(entries: [saved, newTransaction], excludedEntryIDs: [saved.id])
        #expect(relearned.suggestion(for: "Keells Supermarket", kind: .expense,
                                     activeCategories: [groceries, transport])?.categoryID == groceries.id)
    }

    private func entry(_ title: String, category: LedgerCategory) -> LedgerEntry {
        LedgerEntry(id: UUID(), kind: category.kind, amount: 100, title: title,
                    category: category.name, date: .now, note: "", categoryID: category.id)
    }
}
