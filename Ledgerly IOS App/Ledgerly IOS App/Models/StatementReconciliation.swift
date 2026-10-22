import Foundation

struct StatementLine: Identifiable, Equatable {
    let id: Int
    let date: Date
    let description: String
    let kind: EntryKind
    let amount: Decimal
}

struct ParsedStatement {
    let lines: [StatementLine]
    let skippedRows: Int
}

enum StatementParseError: LocalizedError {
    case unreadable, unsupportedLayout, noTransactions, tooManyTransactions

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file has no readable text. Scanned PDFs need a text layer or a CSV export."
        case .unsupportedLayout: "Ledgerly needs a date, description, and debit/credit or signed amount column."
        case .noTransactions: "No dated LKR transactions were found in this statement."
        case .tooManyTransactions: "Import up to 200 statement transactions at a time."
        }
    }
}

enum StatementParser {
    static func csv(_ data: Data) throws -> ParsedStatement {
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw StatementParseError.unreadable
        }
        let rows = csvRows(raw.replacingOccurrences(of: "\u{FEFF}", with: ""))
        guard let headerIndex = rows.firstIndex(where: { row in
            let names = row.map { canonical($0) }
            return names.contains(where: { ["date", "transactiondate", "posteddate", "valuedate"].contains($0) }) &&
                names.contains(where: { ["description", "details", "merchant", "narration", "particulars"].contains($0) }) &&
                names.contains(where: { ["amount", "transactionamount", "value", "debit", "withdrawal", "paidout"].contains($0) })
        }) else { throw StatementParseError.unsupportedLayout }
        let headers = rows[headerIndex].map { canonical($0) }
        func column(_ choices: [String]) -> Int? {
            headers.firstIndex { choices.contains($0) }
        }
        guard let dateIndex = column(["date", "transactiondate", "posteddate", "valuedate"]),
              let descriptionIndex = column(["description", "details", "merchant", "narration", "particulars"])
        else { throw StatementParseError.unsupportedLayout }
        let debitIndex = column(["debit", "withdrawal", "paidout"])
        let creditIndex = column(["credit", "deposit", "paidin"])
        let amountIndex = column(["amount", "transactionamount", "value"])
        let typeIndex = column(["type", "drcr", "transactiontype"])
        guard (debitIndex != nil && creditIndex != nil) || amountIndex != nil else {
            throw StatementParseError.unsupportedLayout
        }
        if (debitIndex == nil || creditIndex == nil), let amountIndex, typeIndex == nil {
            let containsSignedDebit = rows.dropFirst(headerIndex + 1).contains { row in
                row.indices.contains(amountIndex) && (parseAmount(row[amountIndex]) ?? 0) < 0
            }
            guard containsSignedDebit else { throw StatementParseError.unsupportedLayout }
        }

        var lines: [StatementLine] = []
        var skipped = 0
        for (offset, row) in rows.dropFirst(headerIndex + 1).enumerated() where row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let index = headerIndex + offset + 2
            func cell(_ column: Int?) -> String { column.flatMap { row.indices.contains($0) ? row[$0] : nil } ?? "" }
            guard let date = parseDate(cell(dateIndex)),
                  !cell(descriptionIndex).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                skipped += 1
                continue
            }
            let kindAndAmount: (EntryKind, Decimal)?
            if debitIndex != nil && creditIndex != nil {
                let debit = parseAmount(cell(debitIndex)) ?? 0
                let credit = parseAmount(cell(creditIndex)) ?? 0
                if debit > 0 && credit == 0 { kindAndAmount = (.expense, debit) }
                else if credit > 0 && debit == 0 { kindAndAmount = (.income, credit) }
                else { kindAndAmount = nil }
            } else if let signed = parseAmount(cell(amountIndex)) {
                let type = canonical(cell(typeIndex))
                let kind: EntryKind?
                if ["credit", "cr", "income", "deposit", "received"].contains(type) {
                    kind = .income
                } else if ["debit", "dr", "expense", "withdrawal", "payment", "purchase", "pos"].contains(type) {
                    kind = .expense
                } else if typeIndex == nil {
                    kind = signed < 0 ? .expense : .income
                } else {
                    kind = nil
                }
                kindAndAmount = kind.map { ($0, abs(signed)) }
            } else { kindAndAmount = nil }
            guard let (kind, amount) = kindAndAmount, amount > 0 else { skipped += 1; continue }
            lines.append(StatementLine(id: index, date: date,
                                       description: cell(descriptionIndex).trimmingCharacters(in: .whitespacesAndNewlines),
                                       kind: kind, amount: amount))
            if lines.count > 200 { throw StatementParseError.tooManyTransactions }
        }
        guard !lines.isEmpty else { throw StatementParseError.noTransactions }
        return ParsedStatement(lines: lines, skippedRows: skipped)
    }

    static func pdfText(_ text: String) throws -> ParsedStatement {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StatementParseError.unreadable
        }
        var lines: [StatementLine] = []
        var skipped = 0
        for (offset, line) in text.components(separatedBy: .newlines).enumerated() {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 4, let date = parseDate(fields[0]) else { continue }
            let tail = Array(fields.dropFirst())
            let type = canonical(tail.last ?? "")
            let parsed: (EntryKind, Decimal, Int)?
            if ["dr", "debit", "cr", "credit"].contains(type), tail.count >= 3,
               let amount = parseAmount(tail[tail.count - 2]) {
                parsed = (["cr", "credit"].contains(type) ? .income : .expense, abs(amount), 2)
            } else if tail.count >= 3 {
                let debit = parseAmount(tail[tail.count - 2]) ?? 0
                let credit = parseAmount(tail[tail.count - 1]) ?? 0
                if (debit > 0) != (credit > 0) {
                    parsed = debit > 0 ? (.expense, debit, 2) : (.income, credit, 2)
                } else { parsed = nil }
            } else { parsed = nil }
            guard let (kind, amount, trailing) = parsed, amount > 0,
                  tail.count > trailing else { skipped += 1; continue }
            lines.append(StatementLine(id: offset + 1, date: date,
                                       description: tail.dropLast(trailing).joined(separator: " "),
                                       kind: kind, amount: amount))
            if lines.count > 200 { throw StatementParseError.tooManyTransactions }
        }
        guard !lines.isEmpty else { throw StatementParseError.noTransactions }
        return ParsedStatement(lines: lines, skippedRows: skipped)
    }

    private static func canonical(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func parseAmount(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "-" { return nil }
        let negative = trimmed.hasPrefix("(") && trimmed.hasSuffix(")")
        let cleaned = trimmed.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "Rs.", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "LKR", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
        guard let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return negative ? -value : value
    }

    private static func parseDate(_ text: String) -> Date? {
        let hasFourDigitYear = text.range(of: #"^(\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}[-/]\d{1,2}[-/]\d{4}|\d{1,2} [A-Za-z]{3} \d{4})$"#,
                                             options: .regularExpression) != nil
        guard hasFourDigitYear else { return nil }
        let formats = ["yyyy-MM-dd", "yyyy/MM/dd", "dd/MM/yyyy", "dd-MM-yyyy", "d/M/yyyy", "d-M-yyyy",
                       "dd MMM yyyy", "d MMM yyyy"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.isLenient = false
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                    cell.append("\"")
                    index += 1
                } else { quoted.toggle() }
            } else if (character == "," || character == ";") && !quoted {
                row.append(cell); cell = ""
            } else if (character == "\n" || character == "\r") && !quoted {
                if character == "\r" && index + 1 < characters.count && characters[index + 1] == "\n" { index += 1 }
                row.append(cell); cell = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            } else { cell.append(character) }
            index += 1
        }
        row.append(cell)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
}
