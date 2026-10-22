import Foundation

// Shared with the widget extension. Contains no account ID, merchant, or notes.
nonisolated struct BudgetWidgetSnapshot: Codable, Equatable {
    struct Expense: Codable, Equatable {
        let date: Date
        let amount: Decimal
    }

    let monthStart: Date
    let monthEnd: Date
    let budget: Decimal
    let expenses: [Expense]
    let updatedAt: Date
    let amountsHidden: Bool

    init(budget: Decimal, expenses: [Expense], asOf date: Date = .now,
         calendar: Calendar = .current, amountsHidden: Bool = false) {
        let month = calendar.dateInterval(of: .month, for: date)!
        monthStart = month.start
        monthEnd = month.end
        updatedAt = date
        self.amountsHidden = amountsHidden
        self.budget = amountsHidden ? 0 : max(0, budget)
        self.expenses = amountsHidden ? [] : expenses.filter {
            $0.amount > 0 && $0.date >= month.start && $0.date < month.end
        }.sorted { $0.date == $1.date ? $0.amount < $1.amount : $0.date < $1.date }
    }

    func isCurrent(at date: Date, calendar: Calendar = .current) -> Bool {
        guard let month = calendar.dateInterval(of: .month, for: date) else { return false }
        return month.start == monthStart && month.end == monthEnd
    }

    func spent(at date: Date) -> Decimal {
        expenses.filter { $0.date <= date }.reduce(Decimal.zero) { $0 + $1.amount }
    }

    func remaining(at date: Date) -> Decimal { budget - spent(at: date) }

    func fractionUsed(at date: Date) -> Double {
        guard budget > 0 else { return 0 }
        return min(1, max(0, NSDecimalNumber(decimal: spent(at: date) / budget).doubleValue))
    }

    // Future expenses become spent at their recorded time, even while the app is closed.
    func nextUpdate(after date: Date, calendar: Calendar = .current) -> Date {
        let midnight = calendar.startOfDay(for: date).addingTimeInterval(1)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: midnight)!
        let nextExpense = expenses.first { $0.date > date }?.date ?? tomorrow
        return min(tomorrow, nextExpense, monthEnd > date ? monthEnd : tomorrow)
    }

    func hasSameContent(as other: Self) -> Bool {
        monthStart == other.monthStart && monthEnd == other.monthEnd &&
            budget == other.budget && expenses == other.expenses && amountsHidden == other.amountsHidden
    }
}

#if os(iOS)
nonisolated enum BudgetWidgetStorage {
    static let groupID = "group.com.indipa.Ledgerly-IOS-App.budget34HL9WPR6H"
    static let kind = "LedgerlyMonthlyBudget"

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("budget-widget.json")
    }

    static func read() -> BudgetWidgetSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(BudgetWidgetSnapshot.self, from: data)
    }

    @discardableResult
    static func write(_ snapshot: BudgetWidgetSnapshot) throws -> Bool {
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        if let existing = read(), snapshot.hasSameContent(as: existing) { return false }
        try JSONEncoder().encode(snapshot).write(to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    }

    static func clear() throws {
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
#endif
