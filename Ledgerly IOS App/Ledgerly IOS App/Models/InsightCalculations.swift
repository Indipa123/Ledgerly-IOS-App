import Foundation

struct InsightAmount: Identifiable {
    let name: String
    let amount: Decimal
    var id: String { name }
    var chartAmount: Double { NSDecimalNumber(decimal: amount).doubleValue }
}

struct InsightMonth: Identifiable {
    let start: Date
    let income: Decimal
    let expense: Decimal
    var id: Date { start }
}

struct InsightDay: Identifiable {
    let date: Date
    let expense: Decimal
    var id: Date { date }
}

enum InsightCalculations {
    static func categoryTotals(_ entries: [LedgerEntry], asOf: Date = .now,
                               calendar: Calendar = .current) -> [InsightAmount] {
        totals(currentMonthExpenses(entries, asOf: asOf, calendar: calendar), name: { $0.category })
    }

    static func categoryEntries(_ entries: [LedgerEntry], category: String, asOf: Date = .now,
                                calendar: Calendar = .current) -> [LedgerEntry] {
        currentMonthExpenses(entries, asOf: asOf, calendar: calendar)
            .filter { $0.category == category }
            .sorted { $0.date > $1.date }
    }

    private static func currentMonthExpenses(_ entries: [LedgerEntry], asOf: Date,
                                             calendar: Calendar) -> [LedgerEntry] {
        guard let month = calendar.dateInterval(of: .month, for: asOf) else { return [] }
        return entries.filter {
            $0.kind == .expense && month.contains($0.date) && $0.date <= asOf
        }
    }

    static func paymentTotals(_ entries: [LedgerEntry], methods: [LedgerPaymentMethod],
                              asOf: Date = .now, calendar: Calendar = .current) -> [InsightAmount] {
        let names = Dictionary(uniqueKeysWithValues: methods.map { ($0.id, $0.name) })
        return totals(currentMonthExpenses(entries, asOf: asOf, calendar: calendar),
                      name: { paymentName(for: $0, names: names) })
    }

    static func paymentEntries(_ entries: [LedgerEntry], methods: [LedgerPaymentMethod],
                               name: String, cardsOnly: Bool = false, asOf: Date = .now,
                               calendar: Calendar = .current) -> [LedgerEntry] {
        let names = Dictionary(uniqueKeysWithValues: methods.map { ($0.id, $0.name) })
        let cardIDs = Set(methods.filter { $0.kind == .debitCard || $0.kind == .creditCard }.map(\.id))
        return currentMonthExpenses(entries, asOf: asOf, calendar: calendar)
            .filter { entry in
                (!cardsOnly || entry.paymentMethodID.map(cardIDs.contains) == true) &&
                paymentName(for: entry, names: names) == name
            }
            .sorted { $0.date > $1.date }
    }

    static func cardTotals(_ entries: [LedgerEntry], methods: [LedgerPaymentMethod],
                           asOf: Date = .now, calendar: Calendar = .current) -> [InsightAmount] {
        let cards = methods.filter { $0.kind == .debitCard || $0.kind == .creditCard }
        let ids = Set(cards.map(\.id))
        return paymentTotals(entries.filter { $0.paymentMethodID.map(ids.contains) ?? false },
                             methods: cards, asOf: asOf, calendar: calendar)
    }

    static func monthlyTotals(_ entries: [LedgerEntry], count: Int = 6,
                              asOf: Date = .now, calendar: Calendar = .current) -> [InsightMonth] {
        guard count > 0, let current = calendar.dateInterval(of: .month, for: asOf)?.start else { return [] }
        return (0..<count).reversed().compactMap { offset in
            guard let start = calendar.date(byAdding: .month, value: -offset, to: current),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
            let inMonth = entries.filter { $0.date >= start && $0.date < end && $0.date <= asOf }
            return InsightMonth(start: start,
                                income: inMonth.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount },
                                expense: inMonth.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount })
        }
    }

    static func dailyExpenses(_ entries: [LedgerEntry], days: Int = 30,
                              asOf: Date = .now, calendar: Calendar = .current) -> [InsightDay] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: asOf)
        let starts = (0..<days).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        guard let first = starts.first,
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }
        var amounts = Array(repeating: Decimal.zero, count: starts.count)
        // One ledger scan. Calendar-derived boundaries preserve local/DST days;
        // binary search assigns an entry without scanning the ledger for every day.
        for entry in entries where entry.kind == .expense && entry.date >= first &&
            entry.date < end && entry.date <= asOf {
            var lower = 0, upper = starts.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if starts[middle] <= entry.date { lower = middle + 1 }
                else { upper = middle }
            }
            if lower > 0 { amounts[lower - 1] += entry.amount }
        }
        return starts.indices.map { InsightDay(date: starts[$0], expense: amounts[$0]) }
    }

    private static func totals(_ entries: [LedgerEntry], name: (LedgerEntry) -> String) -> [InsightAmount] {
        Dictionary(grouping: entries, by: name)
            .map { InsightAmount(name: $0.key, amount: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.amount == $1.amount ? $0.name < $1.name : $0.amount > $1.amount }
    }

    private static func paymentName(for entry: LedgerEntry, names: [UUID: String]) -> String {
        entry.paymentMethodID.flatMap { names[$0] } ?? "Unspecified"
    }
}
