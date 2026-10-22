import Foundation
import CryptoKit

struct CategoryBudget: Identifiable, Equatable {
    let monthKey: String
    let categoryName: String
    let amount: Decimal
    let updatedAt: Date

    var id: String { Self.key(monthKey: monthKey, categoryName: categoryName) }

    var isValid: Bool {
        amount >= 0 && !categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        Self.isValidMonthKey(monthKey)
    }

    static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    static func key(monthKey: String, categoryName: String) -> String {
        let normalized = categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let digest = SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "category-\(monthKey)-\(digest)"
    }

    static func isValidMonthKey(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]) else { return false }
        return year > 0 && (1...12).contains(month)
    }

    func spent(in entries: [LedgerEntry], month: DateInterval, asOf date: Date) -> Decimal {
        entries.filter { entry in
            entry.kind == .expense && month.contains(entry.date) && entry.date <= date &&
            entry.category.compare(categoryName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }.reduce(0) { $0 + $1.amount }
    }
}
