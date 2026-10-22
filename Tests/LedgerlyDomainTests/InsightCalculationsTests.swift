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

    @Test func categoryDetailExplainsTheDisplayedMonthlyTotal() throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12)))
        let earlier = entry(.expense, amount: 125, category: "Food", on: 2, month: 10, calendar: calendar)
        let later = entry(.expense, amount: 75, category: "Food", on: 4, month: 10, calendar: calendar)
        let entries = [
            earlier, later,
            entry(.expense, amount: 40, category: "Transport", on: 3, month: 10, calendar: calendar),
            entry(.income, amount: 1_000, category: "Food", on: 3, month: 10, calendar: calendar),
            entry(.expense, amount: 60, category: "Food", on: 30, month: 9, calendar: calendar),
            entry(.expense, amount: 90, category: "Food", on: 5, month: 10, calendar: calendar)
        ]

        let detail = InsightCalculations.categoryEntries(entries, category: "Food", asOf: today,
                                                         calendar: calendar)
        let summary = try #require(InsightCalculations.categoryTotals(entries, asOf: today,
                                                                       calendar: calendar).first { $0.name == "Food" })
        #expect(detail.map(\.id) == [later.id, earlier.id])
        #expect(detail.reduce(Decimal.zero) { $0 + $1.amount } == summary.amount)
    }

    @Test func paymentDetailsMatchMethodAndCardTotalsWithMissingMethods() throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12)))
        let card = LedgerPaymentMethod(id: UUID(), name: "My card", kind: .debitCard,
                                       lastFour: "1234", isArchived: true, sortIndex: 0)
        let cash = LedgerPaymentMethod(id: UUID(), name: "Cash", kind: .cash,
                                       lastFour: nil, isArchived: false, sortIndex: 1)
        func paid(_ kind: EntryKind, _ amount: Decimal, _ methodID: UUID?,
                  day: Int, month: Int = 10) -> LedgerEntry {
            var transaction = entry(kind, amount: amount, category: "Food", on: day,
                                    month: month, calendar: calendar)
            transaction.paymentMethodID = methodID
            return transaction
        }
        let entries = [
            paid(.expense, 80, card.id, day: 2),
            paid(.expense, 20, card.id, day: 4),
            paid(.expense, 50, cash.id, day: 3),
            paid(.expense, 25, nil, day: 3),
            paid(.expense, 15, UUID(), day: 3),
            paid(.income, 500, card.id, day: 3),
            paid(.expense, 90, card.id, day: 5),
            paid(.expense, 70, card.id, day: 30, month: 9)
        ]
        let methods = [card, cash]
        let totals = InsightCalculations.paymentTotals(entries, methods: methods,
                                                       asOf: today, calendar: calendar)
        for item in totals {
            let detail = InsightCalculations.paymentEntries(entries, methods: methods,
                                                            name: item.name, asOf: today, calendar: calendar)
            #expect(detail.reduce(Decimal.zero) { $0 + $1.amount } == item.amount)
        }
        let cardTotal = try #require(InsightCalculations.cardTotals(entries, methods: methods,
                                                                    asOf: today, calendar: calendar).first)
        let cardDetail = InsightCalculations.paymentEntries(entries, methods: methods,
                                                            name: cardTotal.name, cardsOnly: true,
                                                            asOf: today, calendar: calendar)
        #expect(cardDetail.map(\.amount) == [20, 80])
        #expect(cardDetail.reduce(Decimal.zero) { $0 + $1.amount } == cardTotal.amount)
        #expect(totals.first(where: { $0.name == "Unspecified" })?.amount == 40)
        #expect(InsightCalculations.paymentEntries(entries, methods: methods, name: "Cash",
                                                   cardsOnly: true, asOf: today,
                                                   calendar: calendar).isEmpty)
    }

    @Test func dailyTrendPreservesLocalMidnightsZeroDaysAndExactAsOfBoundaryAcrossDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func date(_ day: Int, _ hour: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour))!
        }
        let asOf = date(8, 12)
        let rows = [
            LedgerEntry(id: UUID(), kind: .expense, amount: 10, title: "", category: "Food", date: date(6), note: ""),
            LedgerEntry(id: UUID(), kind: .expense, amount: 20, title: "", category: "Food", date: date(8), note: ""),
            LedgerEntry(id: UUID(), kind: .expense, amount: 30, title: "", category: "Food", date: asOf, note: ""),
            LedgerEntry(id: UUID(), kind: .expense, amount: 999, title: "", category: "Food", date: date(6).addingTimeInterval(-1), note: ""),
            LedgerEntry(id: UUID(), kind: .expense, amount: 999, title: "", category: "Food", date: asOf.addingTimeInterval(1), note: ""),
            LedgerEntry(id: UUID(), kind: .income, amount: 999, title: "", category: "Salary", date: date(7), note: "")
        ]
        let result = InsightCalculations.dailyExpenses(rows, days: 3, asOf: asOf, calendar: calendar)
        #expect(result.map(\.date) == [date(6), date(7), date(8)])
        #expect(result.map(\.expense) == [10, 0, 50])
        #expect(InsightCalculations.dailyExpenses(rows, days: 0, asOf: asOf, calendar: calendar).isEmpty)
        #expect(InsightCalculations.dailyExpenses(rows, days: -1, asOf: asOf, calendar: calendar).isEmpty)
    }

    @Test func dailyBucketsMatchIndependentRangeSumsForUnsortedMixedLedgers() {
        for zone in ["Asia/Colombo", "America/New_York", "Pacific/Auckland"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            let asOf = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 12))!
            let entries = (0..<2_000).map { index in
                LedgerEntry(id: UUID(), kind: index.isMultiple(of: 5) ? .income : .expense,
                    amount: Decimal(index % 79) / 100, title: "", category: "Example",
                    date: asOf.addingTimeInterval(Double((index % 160 - 130) * 21_337)), note: "")
            }
            for count in [1, 5, 30, 60] {
                let result = InsightCalculations.dailyExpenses(entries.reversed(), days: count, asOf: asOf, calendar: calendar)
                #expect(result.count == count)
                for bucket in result {
                    let end = calendar.date(byAdding: .day, value: 1, to: bucket.date)!
                    let expected = entries.filter {
                        $0.kind == .expense && $0.date >= bucket.date && $0.date < end && $0.date <= asOf
                    }.reduce(Decimal.zero) { $0 + $1.amount }
                    #expect(bucket.expense == expected)
                }
            }
        }
    }

    private func entry(_ kind: EntryKind, amount: Decimal, category: String,
                       on day: Int, month: Int, calendar: Calendar) -> LedgerEntry {
        LedgerEntry(id: UUID(), kind: kind, amount: amount, title: "",
                    category: category,
                    date: calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9))!,
                    note: "")
    }
}
