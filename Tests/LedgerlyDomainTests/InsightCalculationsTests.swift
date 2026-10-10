import Foundation
import Testing
@testable import LedgerlyDomain

struct InsightCalculationsTests {
    @Test func monthAndCategoryTotalsExcludeFutureEntries() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12))!
        let food = entry(.expense, amount: 125, category: "Food", on: 2, month: 10, calendar: calendar)
        let bus = entry(.expense, amount: 75, category: "Transport", on: 30, month: 9, calendar: calendar)
        let salary = entry(.income, amount: 1_000, category: "Salary", on: 1, month: 10, calendar: calendar)
        let future = entry(.expense, amount: 900, category: "Food", on: 5, month: 10, calendar: calendar)
        let entries = [food, bus, salary, future]

        let category = InsightCalculations.categoryTotals(entries, asOf: today, calendar: calendar)
        #expect(category.count == 1)
        #expect(category.first?.name == "Food")
        #expect(category.first?.amount == 125)
        let months = InsightCalculations.monthlyTotals(entries, count: 2, asOf: today, calendar: calendar)
        #expect(months.count == 2)
        #expect(months[0].expense == 75)
        #expect(months[1].income == 1_000)
        #expect(months[1].expense == 125)
    }

    @Test func dailyTrendIncludesZeroDaysAndPaymentBreakdown() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12))!
        let card = LedgerPaymentMethod(id: UUID(), name: "My debit card", kind: .debitCard,
                                       lastFour: "1234", isArchived: true, sortIndex: 0)
        var expense = entry(.expense, amount: 80, category: "Food", on: 2, month: 10, calendar: calendar)
        expense.paymentMethodID = card.id
        let cash = entry(.expense, amount: 20, category: "Food", on: 4, month: 10, calendar: calendar)
        let entries = [expense, cash]

        let days = InsightCalculations.dailyExpenses(entries, days: 3, asOf: today, calendar: calendar)
        #expect(days.map(\.expense) == [80, 0, 20])
        let payments = InsightCalculations.paymentTotals(entries, methods: [card], asOf: today, calendar: calendar)
        #expect(payments.map(\.name) == ["My debit card", "Unspecified"])
        #expect(InsightCalculations.cardTotals(entries, methods: [card], asOf: today,
                                               calendar: calendar).first?.amount == 80)
    }

    private func entry(_ kind: EntryKind, amount: Decimal, category: String,
                       on day: Int, month: Int, calendar: Calendar) -> LedgerEntry {
        LedgerEntry(id: UUID(), kind: kind, amount: amount, title: "",
                    category: category,
                    date: calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9))!,
                    note: "")
    }
}
