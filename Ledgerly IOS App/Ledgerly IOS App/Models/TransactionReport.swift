import Foundation

struct ReportCategoryTotal: Identifiable {
    let name: String
    let amount: Decimal
    var id: String { name }
}

/// A selected, inclusive range of transaction dates. It contains no receipt images,
/// learned-category examples, saved-place list, or place-visit history.
struct TransactionReport {
    let startDay: Date
    let endDay: Date
    let entries: [LedgerEntry]

    init?(entries: [LedgerEntry], startDay: Date, endDay: Date,
          calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: startDay)
        let finalDay = calendar.startOfDay(for: endDay)
        guard start <= finalDay,
              let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: finalDay) else { return nil }
        self.startDay = start
        self.endDay = finalDay
        self.entries = entries.filter { $0.date >= start && $0.date < exclusiveEnd }
            .sorted { lhs, rhs in
                lhs.date == rhs.date ? lhs.id.uuidString < rhs.id.uuidString : lhs.date > rhs.date
            }
    }

    var income: Decimal {
        entries.lazy.filter { $0.kind == .income }.reduce(Decimal.zero) { $0 + $1.amount }
    }

    var expense: Decimal {
        entries.lazy.filter { $0.kind == .expense }.reduce(Decimal.zero) { $0 + $1.amount }
    }

    var net: Decimal { income - expense }

    var expenseByCategory: [ReportCategoryTotal] {
        Dictionary(grouping: entries.filter { $0.kind == .expense }, by: \.category)
            .map { ReportCategoryTotal(name: $0.key, amount: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.amount == $1.amount ? $0.name < $1.name : $0.amount > $1.amount }
    }

    func csv(paymentMethods: [LedgerPaymentMethod], includeLocations: Bool = false,
             timeZone: TimeZone = .current) -> String {
        let methodNames = Dictionary(uniqueKeysWithValues: paymentMethods.map { ($0.id, $0.name) })
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        var rows = [["Transaction ID", "Date and time", "Type", "Amount (LKR)",
                     "Description", "Category", "Payment method", "Note"]]
        if includeLocations { rows[0] += ["Place", "Latitude", "Longitude"] }

        for entry in entries {
            var fields = [
                entry.id.uuidString, formatter.string(from: entry.date), entry.kind.label,
                NSDecimalNumber(decimal: entry.amount).stringValue, entry.title, entry.category,
                entry.paymentMethodID.flatMap { methodNames[$0] } ?? "", entry.note
            ]
            if includeLocations {
                let location = entry.location.flatMap { $0.isValid ? $0 : nil }
                fields += [location?.name ?? "", location.map { String($0.latitude) } ?? "",
                           location.map { String($0.longitude) } ?? ""]
            }
            rows.append(fields)
        }
        return rows.map { $0.map(Self.csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    nonisolated private static func csvField(_ raw: String) -> String {
        // Quoting handles commas and line breaks. A leading apostrophe stops spreadsheet
        // applications from evaluating user-entered descriptions as formulas.
        let firstVisible = raw.trimmingCharacters(in: .whitespacesAndNewlines).first
        let safe = firstVisible.map { "=+-@".contains($0) } == true ? "'" + raw : raw
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
