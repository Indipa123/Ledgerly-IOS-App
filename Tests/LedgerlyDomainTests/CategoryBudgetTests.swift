import Foundation
import Testing
@testable import LedgerlyDomain

@MainActor
struct CategoryBudgetTests {
    @Test func categoryLimitPersistsForItsMonthAndRemovalWinsOverOlderCloudData() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let month = CategoryBudget.monthKey(for: .now)
        let limit = CategoryBudget(monthKey: month, categoryName: "Groceries",
                                   amount: Decimal(string: "1200.50")!, updatedAt: first)
        try repository.setCategoryBudget(limit)
        #expect(try repository.fetchCategoryBudgets(monthKey: month).first?.amount == limit.amount)
        #expect(try repository.fetchCategoryBudgets(monthKey: "2001-01").isEmpty)

        let removed = CategoryBudget(monthKey: month, categoryName: "Groceries",
                                     amount: 0, updatedAt: first.addingTimeInterval(60))
        try repository.setCategoryBudget(removed)
        try repository.applyRemote(limit)
        #expect(try repository.fetchCategoryBudgets(monthKey: month).isEmpty)
        #expect(try repository.allCategoryBudgetsForSync().contains { $0.id == removed.id && $0.amount == 0 })
    }

    @Test func categorySpendingExcludesIncomeOtherMonthsAndFutureExpenses() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let monthStart = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        let month = try #require(calendar.dateInterval(of: .month, for: monthStart))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15)))
        func entry(_ kind: EntryKind, _ amount: Decimal, _ category: String, _ date: Date) -> LedgerEntry {
            LedgerEntry(id: UUID(), kind: kind, amount: amount, title: "", category: category,
                        date: date, note: "")
        }
        let entries = [
            entry(.expense, 430, "Groceries", today.addingTimeInterval(-3600)),
            entry(.expense, 20, "groceries", today.addingTimeInterval(-7200)),
            entry(.income, 500, "Groceries", today.addingTimeInterval(-3600)),
            entry(.expense, 200, "Groceries", today.addingTimeInterval(3600)),
            entry(.expense, 50, "Groceries", monthStart.addingTimeInterval(-3600)),
            entry(.expense, 70, "Transport", today.addingTimeInterval(-3600))
        ]
        let limit = CategoryBudget(monthKey: "2026-10", categoryName: "Groceries",
                                   amount: 1000, updatedAt: today)
        #expect(limit.spent(in: entries, month: month, asOf: today) == 450)
        #expect(CategoryBudget.key(monthKey: "2026-10", categoryName: " GROCERIES ") == limit.id)
    }

    @Test func remoteLimitCreatesItsExpenseCategoryOnAnotherDevice() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let limit = CategoryBudget(monthKey: CategoryBudget.monthKey(for: .now),
                                   categoryName: "Course materials", amount: 2500, updatedAt: .now)
        try repository.applyRemote(limit)
        #expect(try repository.fetchCategories().contains {
            $0.name == "Course materials" && $0.kind == .expense && !$0.isArchived
        })
        #expect(try repository.fetchCategoryBudgets(monthKey: limit.monthKey).contains { $0.id == limit.id })
    }

    @Test func categoryAlertsFollowOnlyThisMonthsExpenseCrossings() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15)))
        let month = try #require(calendar.dateInterval(of: .month, for: now))
        let limit = CategoryBudget(monthKey: "2026-10", categoryName: "Groceries",
                                   amount: 1000, updatedAt: now)
        func entry(_ amount: Decimal, _ category: String, _ kind: EntryKind = .expense,
                   _ date: Date) -> LedgerEntry {
            LedgerEntry(id: UUID(), kind: kind, amount: amount, title: "", category: category,
                        date: date, note: "")
        }
        let earlier = entry(790, "Groceries", .expense, now.addingTimeInterval(-3600))
        let warning = entry(10, "groceries", .expense, now.addingTimeInterval(-1800))
        let reached = entry(200, "Groceries", .expense, now.addingTimeInterval(-900))
        let unrelated = [entry(300, "Transport", .expense, now.addingTimeInterval(-600)),
                         entry(300, "Groceries", .income, now.addingTimeInterval(-600)),
                         entry(300, "Groceries", .expense, now.addingTimeInterval(3600))]
        let before = limit.spent(in: [earlier] + unrelated, month: month, asOf: now)
        let atWarning = limit.spent(in: [earlier, warning] + unrelated, month: month, asOf: now)
        let atLimit = limit.spent(in: [earlier, warning, reached] + unrelated, month: month, asOf: now)

        #expect(BudgetAlertDecision.crossing(from: before, to: atWarning,
                                             budget: limit.amount) == .warning)
        #expect(BudgetAlertDecision.crossing(from: atWarning, to: atLimit,
                                             budget: limit.amount) == .overBudget)
        #expect(BudgetAlertDecision.crossing(from: atLimit, to: atLimit,
                                             budget: limit.amount) == .none)
        #expect(limit.id != CategoryBudget.key(monthKey: "2026-10", categoryName: "Transport"))
        #expect(limit.id != CategoryBudget.key(monthKey: "2026-11", categoryName: "Groceries"))
    }
}
