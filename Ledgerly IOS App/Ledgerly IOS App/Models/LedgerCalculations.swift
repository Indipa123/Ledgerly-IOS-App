import Foundation

struct LedgerTotals: Equatable {
    let income: Decimal
    let expense: Decimal
    let spentSoFar: Decimal

    var balance: Decimal { income - expense }
    func remaining(from budget: Decimal) -> Decimal { budget - spentSoFar }
    func isOverBudget(_ budget: Decimal) -> Bool { budget > 0 && spentSoFar > budget }
    func reachedWarning(_ budget: Decimal) -> Bool { budget > 0 && spentSoFar >= budget * Decimal(string: "0.8")! }
}

enum LedgerCalculations {
    static func totals(_ entries: [LedgerEntry], in interval: DateInterval, asOf today: Date) -> LedgerTotals {
        let relevant = entries.filter { interval.contains($0.date) }
        let income = relevant.filter { $0.kind == .income }.reduce(Decimal.zero) { $0 + $1.amount }
        let expense = relevant.filter { $0.kind == .expense }.reduce(Decimal.zero) { $0 + $1.amount }
        let spent = relevant.filter { $0.kind == .expense && $0.date <= today }.reduce(Decimal.zero) { $0 + $1.amount }
        return LedgerTotals(income: income, expense: expense, spentSoFar: spent)
    }
}

enum TransactionPeriod: String, CaseIterable, Identifiable {
    case thisMonth = "This month"
    case lastMonth = "Last month"
    case lastThreeMonths = "Last 3 months"
    case allTime = "All time"
    case custom = "Custom"
    var id: Self { self }

    func interval(asOf date: Date, calendar: Calendar = .current, start: Date? = nil, end: Date? = nil) -> DateInterval? {
        let month = calendar.dateInterval(of: .month, for: date)
        switch self {
        case .thisMonth: return month
        case .lastMonth:
            guard let beginning = month?.start, let previous = calendar.date(byAdding: .month, value: -1, to: beginning) else { return nil }
            return DateInterval(start: previous, end: beginning)
        case .lastThreeMonths:
            guard let beginning = month?.start, let first = calendar.date(byAdding: .month, value: -2, to: beginning),
                  let end = calendar.date(byAdding: .month, value: 1, to: beginning) else { return nil }
            return DateInterval(start: first, end: end)
        case .allTime: return nil
        case .custom:
            guard let start, let end, start <= end,
                  let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) else { return nil }
            return DateInterval(start: calendar.startOfDay(for: start), end: exclusiveEnd)
        }
    }
}

enum TransactionSort: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case oldest = "Oldest"
    case highestAmount = "Highest amount"
    case lowestAmount = "Lowest amount"
    case category = "Category"
    var id: Self { self }
}

struct TransactionQuery {
    var kind: EntryKind?
    var search = ""
    var period: TransactionPeriod = .allTime
    var startDate: Date?
    var endDate: Date?
    var categoryID: UUID?
    var paymentMethodID: UUID?
    var minimumAmount: Decimal?
    var maximumAmount: Decimal?
    var sort: TransactionSort = .newest

    func apply(to entries: [LedgerEntry], asOf today: Date, calendar: Calendar = .current) -> [LedgerEntry] {
        let range = period.interval(asOf: today, calendar: calendar, start: startDate, end: endDate)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = entries.filter { entry in
            if let kind, entry.kind != kind { return false }
            if period == .custom && range == nil { return false }
            if let range, !range.contains(entry.date) { return false }
            if let categoryID, entry.categoryID != categoryID { return false }
            if let paymentMethodID, entry.paymentMethodID != paymentMethodID { return false }
            if let minimumAmount, entry.amount < minimumAmount { return false }
            if let maximumAmount, entry.amount > maximumAmount { return false }
            if !query.isEmpty &&
                !entry.title.localizedStandardContains(query) &&
                !entry.note.localizedStandardContains(query) &&
                !entry.category.localizedStandardContains(query) &&
                !NSDecimalNumber(decimal: entry.amount).stringValue.localizedStandardContains(query) {
                return false
            }
            return true
        }
        return result.sorted { lhs, rhs in
            switch sort {
            case .newest: return lhs.date == rhs.date ? lhs.id.uuidString < rhs.id.uuidString : lhs.date > rhs.date
            case .oldest: return lhs.date == rhs.date ? lhs.id.uuidString < rhs.id.uuidString : lhs.date < rhs.date
            case .highestAmount: return lhs.amount == rhs.amount ? lhs.date > rhs.date : lhs.amount > rhs.amount
            case .lowestAmount: return lhs.amount == rhs.amount ? lhs.date > rhs.date : lhs.amount < rhs.amount
            case .category: return lhs.category == rhs.category ? lhs.date > rhs.date : lhs.category < rhs.category
            }
        }
    }
}
