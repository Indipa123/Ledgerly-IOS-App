import Foundation
import Testing
@testable import LedgerlyDomain

struct BudgetWidgetTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 19_800)!
        return calendar
    }

    private func date(_ day: Int, month: Int = 10, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test func countsOnlyThisMonthsExpensesDueByNow() {
        let snapshot = BudgetWidgetSnapshot(budget: 1_000, expenses: [
            .init(date: date(1, month: 9), amount: 900),
            .init(date: date(1), amount: Decimal(string: "400.25")!),
            .init(date: date(17, hour: 18), amount: 200),
            .init(date: date(1, month: 11, hour: 0), amount: 800)
        ], asOf: date(17), calendar: calendar)
        #expect(snapshot.expenses.count == 2)
        #expect(snapshot.spent(at: date(17)) == Decimal(string: "400.25")!)
        #expect(snapshot.remaining(at: date(17)) == Decimal(string: "599.75")!)
        #expect(snapshot.spent(at: date(18)) == Decimal(string: "600.25")!)
        #expect(snapshot.nextUpdate(after: date(17), calendar: calendar) == date(17, hour: 18))
    }

    @Test func preservesOverBudgetAmountAndAvoidsDividingByZero() {
        let snapshot = BudgetWidgetSnapshot(budget: 500, expenses: [
            .init(date: date(1), amount: 750)
        ], asOf: date(17), calendar: calendar)
        #expect(snapshot.remaining(at: date(17)) == -250)
        #expect(snapshot.fractionUsed(at: date(17)) == 1)
        let noBudget = BudgetWidgetSnapshot(budget: 0, expenses: snapshot.expenses,
                                            asOf: date(17), calendar: calendar)
        #expect(noBudget.fractionUsed(at: date(17)) == 0)
        #expect(noBudget.spent(at: date(17)) == 750)
    }

    @Test func expiresAtMonthBoundaryAndRequestsAnUpdateThere() {
        let snapshot = BudgetWidgetSnapshot(budget: 500, expenses: [], asOf: date(31), calendar: calendar)
        let nextMonth = date(1, month: 11, hour: 0)
        #expect(snapshot.isCurrent(at: date(31), calendar: calendar))
        #expect(!snapshot.isCurrent(at: nextMonth, calendar: calendar))
        #expect(snapshot.nextUpdate(after: date(31), calendar: calendar) == nextMonth)
        #expect(snapshot.nextUpdate(after: nextMonth, calendar: calendar) > nextMonth)
    }

    @Test func appLockRemovesAmountsFromTheSharedPayload() throws {
        let snapshot = BudgetWidgetSnapshot(budget: 5_000, expenses: [
            .init(date: date(1), amount: 700)
        ], asOf: date(17), calendar: calendar, amountsHidden: true)
        let restored = try JSONDecoder().decode(BudgetWidgetSnapshot.self,
                                                 from: JSONEncoder().encode(snapshot))
        #expect(restored.amountsHidden)
        #expect(restored.budget == 0)
        #expect(restored.expenses.isEmpty)
        #expect(restored == snapshot)
    }
}
