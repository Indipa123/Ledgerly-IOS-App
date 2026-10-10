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
        guard let month = calendar.dateInterval(of: .month, for: asOf) else { return [] }
        return totals(entries.filter {
            $0.kind == .expense && month.contains($0.date) && $0.date <= asOf
        }, name: { $0.category })
    }

    static func paymentTotals(_ entries: [LedgerEntry], methods: [LedgerPaymentMethod],
                              asOf: Date = .now, calendar: Calendar = .current) -> [InsightAmount] {
        guard let month = calendar.dateInterval(of: .month, for: asOf) else { return [] }
        let names = Dictionary(uniqueKeysWithValues: methods.map { ($0.id, $0.name) })
        return totals(entries.filter {
            $0.kind == .expense && month.contains($0.date) && $0.date <= asOf
        }, name: { $0.paymentMethodID.flatMap { names[$0] } ?? "Unspecified" })
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
        return (0..<days).reversed().compactMap { offset in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let amount = entries.filter {
                $0.kind == .expense && $0.date >= start && $0.date < end && $0.date <= asOf
            }.reduce(Decimal.zero) { $0 + $1.amount }
            return InsightDay(date: start, expense: amount)
        }
    }

    private static func totals(_ entries: [LedgerEntry], name: (LedgerEntry) -> String) -> [InsightAmount] {
        Dictionary(grouping: entries, by: name)
            .map { InsightAmount(name: $0.key, amount: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.amount == $1.amount ? $0.name < $1.name : $0.amount > $1.amount }
    }
}
