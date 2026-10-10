import Foundation

struct ReceiptSuggestions: Sendable {
    var merchant: String?
    var amount: Decimal?
    var date: Date?
    var dateCandidates: [ReceiptDateCandidate]
    var lines: [String]
}

struct ReceiptDateCandidate: Identifiable, Sendable {
    let date: Date
    let format: String
    var id: String { "\(date.timeIntervalSince1970)-\(format)" }
}

enum ReceiptTextParser {
    nonisolated static func parse(_ lines: [String], asOf: Date = .now) -> ReceiptSuggestions {
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let merchant = cleaned.prefix(5).first { line in
            line.rangeOfCharacter(from: .letters) != nil &&
            !line.lowercased().contains("receipt") &&
            !line.lowercased().contains("invoice") &&
            !line.lowercased().contains("date") &&
            !line.lowercased().contains("total")
        }
        let totalLines = cleaned.filter { line in
            let lower = line.lowercased()
            return (lower.contains("total") || lower.contains("amount due")) &&
                !lower.contains("subtotal") && !lower.contains("sub total") &&
                !lower.contains("tax") && !lower.contains("saving")
        }
        let amount = totalLines.reversed().compactMap(lastAmount(in:)).first
        let dates = cleaned.map { dateCandidates(in: $0, asOf: asOf) }.first { !$0.isEmpty } ?? []
        let ordered = dates.sorted { distance($0.date, from: asOf) < distance($1.date, from: asOf) }
        return ReceiptSuggestions(merchant: merchant, amount: amount,
                                  date: ordered.count == 1 ? ordered.first?.date : nil,
                                  dateCandidates: ordered, lines: cleaned)
    }

    nonisolated private static func lastAmount(in line: String) -> Decimal? {
        let pattern = #"\b\d{1,3}(?:,\d{3})+(?:\.\d{2})?\b|\b\d+(?:\.\d{2})?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.matches(in: line, range: range).reversed().compactMap { match in
            guard let range = Range(match.range, in: line) else { return nil }
            return Decimal(string: line[range].replacingOccurrences(of: ",", with: ""))
        }.first
    }

    nonisolated private static func distance(_ date: Date, from reference: Date) -> TimeInterval {
        abs(date.timeIntervalSince(reference))
    }

    nonisolated private static func dateCandidates(in line: String, asOf: Date) -> [ReceiptDateCandidate] {
        let pattern = #"\b(?:\d{1,2}[/-]\d{1,2}[/-](?:\d{4}|\d{2})|\d{4}[/-]\d{1,2}[/-]\d{1,2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let range = Range(match.range, in: line) else { return [] }
        let text = String(line[range])
        let pieces = text.split(whereSeparator: { $0 == "/" || $0 == "-" })
        guard pieces.count == 3, let first = Int(pieces[0]), let second = Int(pieces[1]),
              let third = Int(pieces[2]) else { return [] }
        let currentYear = Calendar.current.component(.year, from: asOf)
        func year(_ twoDigits: Int) -> Int {
            let candidate = (currentYear / 100) * 100 + twoDigits
            return candidate > currentYear + 1 ? candidate - 100 : candidate
        }
        var options: [ReceiptDateCandidate] = []
        func add(_ year: Int, _ month: Int, _ day: Int, _ format: String) {
            guard (1900...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let parts = DateComponents(year: year, month: month, day: day, hour: 12)
            guard let date = calendar.date(from: parts),
                  calendar.component(.year, from: date) == year,
                  calendar.component(.month, from: date) == month,
                  calendar.component(.day, from: date) == day else { return }
            if !options.contains(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
                options.append(ReceiptDateCandidate(date: date, format: format))
            }
        }
        if pieces[0].count == 4 {
            add(first, second, third, "YYYY-MM-DD")
        } else if pieces[2].count == 4 {
            add(third, second, first, "DD-MM-YYYY")
            add(third, first, second, "MM-DD-YYYY")
        } else {
            add(year(first), second, third, "YY-MM-DD")
            add(year(third), second, first, "DD-MM-YY")
            add(year(third), first, second, "MM-DD-YY")
        }
        return options
    }
}
