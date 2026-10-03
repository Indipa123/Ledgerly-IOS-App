import Foundation
import Testing
@testable import LedgerlyDomain

struct LedgerCalculationsTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func entry(
        _ kind: EntryKind,
        _ amount: String,
        _ day: Int,
        title: String = "Entry",
        category: String = "Other",
        categoryID: UUID? = nil,
        methodID: UUID? = nil
    ) -> LedgerEntry {
        LedgerEntry(
            id: UUID(), kind: kind, amount: Decimal(string: amount)!,
            title: title, category: category, date: date(2026, 9, day), note: "",
            categoryID: categoryID, paymentMethodID: methodID
        )
    }

    @Test func decimalTotalsAndFutureSpending() {
        let interval = calendar.dateInterval(of: .month, for: date(2026, 9, 15))!
        let entries = [
            entry(.income, "1000.10", 1),
            entry(.expense, "100.05", 10),
            entry(.expense, "50.20", 25),
            LedgerEntry(id: UUID(), kind: .expense, amount: 999, title: "August",
                        category: "Other", date: date(2026, 8, 31), note: "")
        ]
        let totals = LedgerCalculations.totals(entries, in: interval, asOf: date(2026, 9, 15))
        #expect(totals.income == Decimal(string: "1000.10")!)
        #expect(totals.expense == Decimal(string: "150.25")!)
        #expect(totals.spentSoFar == Decimal(string: "100.05")!)
        #expect(totals.balance == Decimal(string: "849.85")!)
        #expect(totals.remaining(from: 200) == Decimal(string: "99.95")!)
    }

    @Test func budgetThresholdsHaveExactBoundaries() {
        let below = LedgerTotals(income: 0, expense: 799, spentSoFar: 799)
        let warning = LedgerTotals(income: 0, expense: 800, spentSoFar: 800)
        let exactlyFull = LedgerTotals(income: 0, expense: 1000, spentSoFar: 1000)
        let over = LedgerTotals(income: 0, expense: 1000.01, spentSoFar: 1000.01)
        #expect(!below.reachedWarning(1000))
        #expect(warning.reachedWarning(1000))
        #expect(!exactlyFull.isOverBudget(1000))
        #expect(over.isOverBudget(1000))
        #expect(!over.reachedWarning(0))
    }

    @Test func filtersComposeAndSort() {
        let foodID = UUID()
        let cashID = UUID()
        let entries = [
            entry(.expense, "25", 5, title: "Canteen", category: "Food", categoryID: foodID, methodID: cashID),
            entry(.expense, "75", 10, title: "Canteen", category: "Food", categoryID: foodID, methodID: cashID),
            entry(.expense, "100", 12, title: "Bus", category: "Transport", methodID: cashID),
            entry(.income, "500", 13, title: "Salary")
        ]
        var query = TransactionQuery()
        query.kind = .expense
        query.search = "canteen"
        query.period = .thisMonth
        query.categoryID = foodID
        query.paymentMethodID = cashID
        query.minimumAmount = 20
        query.maximumAmount = 80
        query.sort = .highestAmount
        let result = query.apply(to: entries, asOf: date(2026, 9, 15), calendar: calendar)
        #expect(result.map(\.amount) == [75, 25])
    }

    @Test func customDateIncludesFinalDay() {
        let entries = [
            entry(.expense, "10", 4),
            entry(.expense, "20", 5),
            entry(.expense, "30", 6)
        ]
        var query = TransactionQuery()
        query.period = .custom
        query.startDate = date(2026, 9, 5)
        query.endDate = date(2026, 9, 5)
        #expect(query.apply(to: entries, asOf: date(2026, 9, 15), calendar: calendar).map(\.amount) == [20])
        query.endDate = date(2026, 9, 4)
        #expect(query.apply(to: entries, asOf: date(2026, 9, 15), calendar: calendar).isEmpty)
    }
}
