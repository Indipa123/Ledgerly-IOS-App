import Foundation
import Testing
@testable import LedgerlyDomain

@MainActor
struct LedgerRepositoryTests {
    @Test func seedsCategoriesAndPaymentMethods() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let categories = try repository.fetchCategories()
        let methods = try repository.fetchPaymentMethods()
        #expect(categories.contains { $0.name == "Groceries" && $0.kind == .expense })
        #expect(categories.contains { $0.name == "Salary" && $0.kind == .income })
        #expect(methods.map(\.name) == ["Cash", "Debit card", "Credit card"])
    }

    @Test func persistsEntryAndBudgetWithoutRounding() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let category = try #require(repository.fetchCategories().first {
            $0.name == "Groceries" && $0.kind == .expense
        })
        let cash = try #require(repository.fetchPaymentMethods().first { $0.kind == .cash })
        let original = LedgerEntry(
            id: UUID(), kind: .expense, amount: Decimal(string: "125.55")!,
            title: "Keells", category: category.name, date: .now, note: "Weekly shop",
            categoryID: category.id, paymentMethodID: cash.id
        )
        try repository.upsert(original)
        try repository.setCurrentBudget(Decimal(string: "1000.10")!)
        let saved = try #require(repository.fetchEntries().first)
        #expect(saved.amount == Decimal(string: "125.55")!)
        #expect(saved.categoryID == category.id)
        #expect(saved.paymentMethodID == cash.id)
        #expect(try repository.fetchCurrentBudget() == Decimal(string: "1000.10")!)
        try repository.softDelete(id: original.id)
        #expect(try repository.fetchEntries().isEmpty)
    }

    @Test func archivedCategoryCannotBeUsedForNewEntry() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let category = try #require(repository.fetchCategories().first { $0.kind == .expense })
        try repository.archiveCategory(id: category.id)
        let entry = LedgerEntry(
            id: UUID(), kind: .expense, amount: 1, title: "Test",
            category: category.name, date: .now, note: "", categoryID: category.id
        )
        #expect(throws: LedgerDataError.self) {
            try repository.upsert(entry)
        }
    }

    @Test func duplicateCategoryNamesAreCaseInsensitive() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let category = LedgerCategory(
            id: UUID(), name: "groceries", kind: .expense,
            isSystem: false, isArchived: false, sortIndex: 100
        )
        #expect(throws: LedgerDataError.self) {
            try repository.saveCategory(category)
        }
    }

    @Test func renamingCategoryUpdatesHistoricalDisplay() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        var category = try #require(repository.fetchCategories().first {
            $0.name == "Groceries" && $0.kind == .expense
        })
        let entry = LedgerEntry(id: UUID(), kind: .expense, amount: 10, title: "Shop",
                                category: "Groceries", date: .now, note: "", categoryID: category.id)
        try repository.upsert(entry)
        category.name = "Food shopping"
        try repository.saveCategory(category)
        #expect(try repository.fetchEntries().first?.category == "Food shopping")
    }

    @Test func paymentMethodAcceptsOnlyOptionalLastFour() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let card = LedgerPaymentMethod(id: UUID(), name: "My debit card", kind: .debitCard,
                                       lastFour: "123", isArchived: false, sortIndex: 10)
        #expect(throws: LedgerDataError.self) {
            try repository.savePaymentMethod(card)
        }
        var valid = card
        valid.lastFour = "1234"
        try repository.savePaymentMethod(valid)
        #expect(try repository.fetchPaymentMethods().contains {
            $0.id == valid.id && $0.lastFour == "1234"
        })
    }

    @Test func remoteUpdatesRespectNewerLocalChangesAndTombstones() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let id = UUID()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = old.addingTimeInterval(60)
        let entry = CloudEntry(id: id, kind: .expense, amount: 25, title: "Lunch",
                               category: "Food & Drink", date: old, note: "",
                               createdAt: old, updatedAt: old, deletedAt: nil)
        try repository.applyRemote(entry)
        #expect(try repository.fetchEntries().first?.title == "Lunch")
        let deleted = CloudEntry(id: id, kind: .expense, amount: 25, title: "Lunch",
                                 category: "Food & Drink", date: old, note: "",
                                 createdAt: old, updatedAt: newer, deletedAt: newer)
        try repository.applyRemote(deleted)
        #expect(try repository.fetchEntries().isEmpty)
        try repository.applyRemote(entry)
        #expect(try repository.fetchEntries().isEmpty)
    }

    @Test func remoteBudgetAppliesOnlyWhenNewer() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: .now))!
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try repository.applyRemote(CloudBudget(month: month, amount: 1000, updatedAt: old))
        try repository.applyRemote(CloudBudget(month: month, amount: 500, updatedAt: old.addingTimeInterval(-1)))
        #expect(try repository.fetchCurrentBudget() == 1000)
    }

    @Test func transactionWithoutDescriptionUsesCategoryAsDisplayTitle() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let salary = try #require(repository.fetchCategories().first {
            $0.name == "Salary" && $0.kind == .income
        })
        let entry = LedgerEntry(id: UUID(), kind: .income, amount: 50_000,
                                title: "", category: salary.name, date: .now, note: "",
                                categoryID: salary.id)
        try repository.upsert(entry)
        let saved = try #require(repository.fetchEntries().first)
        #expect(saved.title.isEmpty)
        #expect(saved.displayTitle == "Salary")
    }
}
