import Foundation

struct ReconciledPair: Identifiable {
    let statement: StatementLine
    let entry: LedgerEntry
    let cost: Double
    let explanation: String
    var id: Int { statement.id }
    var amountConflict: Bool { statement.amount != entry.amount }
}

struct ReconciliationResult {
    let matched: [ReconciledPair]
    let amountConflicts: [ReconciledPair]
    let missingInApp: [StatementLine]
    let missingOnStatement: [LedgerEntry]
}

enum ReconciliationMatcher {
    private static let unmatchedCost = 0.72

    static func compare(_ lines: [StatementLine], with entries: [LedgerEntry]) -> ReconciliationResult {
        guard !lines.isEmpty else {
            return ReconciliationResult(matched: [], amountConflicts: [],
                                        missingInApp: [], missingOnStatement: [])
        }
        let calendar = Calendar(identifier: .gregorian)
        let first = lines.map(\.date).min()!
        let last = lines.map(\.date).max()!
        let pool = entries.filter {
            $0.date >= first.addingTimeInterval(-8 * 86_400) &&
            $0.date <= last.addingTimeInterval(8 * 86_400)
        }.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        let poolScores = lines.map { line in pool.map { pairCost(line, $0, calendar: calendar) } }
        let candidateIndices = pool.indices.filter { index in poolScores.contains { $0[index] != nil } }
        let candidates = candidateIndices.map { pool[$0] }
        let scores = poolScores.map { row in candidateIndices.map { row[$0] } }
        let costs = scores.enumerated().map { _, values in
            values.map { $0 ?? 10 } + (0..<lines.count).map { _ in unmatchedCost }
        }
        let assignment = minimumAssignment(costs)
        var matched: [ReconciledPair] = []
        var conflicts: [ReconciledPair] = []
        var missing: [StatementLine] = []
        var usedEntries = Set<UUID>()
        for (index, column) in assignment.enumerated() {
            guard column < candidates.count, let cost = scores[index][column], cost < unmatchedCost else {
                missing.append(lines[index])
                continue
            }
            let entry = candidates[column]
            usedEntries.insert(entry.id)
            let pair = ReconciledPair(statement: lines[index], entry: entry, cost: cost,
                                      explanation: explanation(lines[index], entry, calendar: calendar))
            if pair.amountConflict { conflicts.append(pair) } else { matched.append(pair) }
        }
        let statementDays = DateInterval(start: calendar.startOfDay(for: first),
                                         end: calendar.date(byAdding: .day, value: 1,
                                                            to: calendar.startOfDay(for: last)) ?? last)
        let unmatchedEntries = entries.filter {
            statementDays.contains($0.date) && !usedEntries.contains($0.id)
        }.sorted { $0.date > $1.date }
        return ReconciliationResult(matched: matched, amountConflicts: conflicts,
                                    missingInApp: missing, missingOnStatement: unmatchedEntries)
    }

    private static func pairCost(_ line: StatementLine, _ entry: LedgerEntry,
                                 calendar: Calendar) -> Double? {
        guard line.kind == entry.kind else { return nil }
        let gap = abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: line.date),
                                              to: calendar.startOfDay(for: entry.date)).day ?? 999)
        guard gap <= 7 else { return nil }
        let statementAmount = NSDecimalNumber(decimal: line.amount).doubleValue
        let savedAmount = NSDecimalNumber(decimal: entry.amount).doubleValue
        let relativeDifference = abs(statementAmount - savedAmount) / max(100, statementAmount)
        guard relativeDifference <= 0.35 else { return nil }
        let similarity = textSimilarity(line.description, entry.displayTitle)
        guard similarity >= 0.55 else { return nil }
        return 0.55 * min(1, relativeDifference / 0.35) +
            0.20 * Double(gap) / 7 + 0.25 * (1 - similarity)
    }

    private static func explanation(_ line: StatementLine, _ entry: LedgerEntry,
                                    calendar: Calendar) -> String {
        let gap = abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: line.date),
                                              to: calendar.startOfDay(for: entry.date)).day ?? 0)
        let amount = line.amount == entry.amount ? "Amounts agree" :
            "Amount differs by \(LKR.string(abs(line.amount - entry.amount)))"
        let date = gap == 0 ? "same date" : "\(gap) \(gap == 1 ? "day" : "days") apart"
        return "\(amount); \(date); similar descriptions. Check the original statement before accepting a change."
    }

    private static func textSimilarity(_ left: String, _ right: String) -> Double {
        let a = words(left), b = words(right)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let aSet = Set(a), bSet = Set(b)
        let tokenScore = Double(aSet.intersection(bSet).count) / Double(aSet.union(bSet).count)
        return 0.6 * jaroWinkler(a.joined(separator: " "), b.joined(separator: " ")) +
            0.4 * tokenScore
    }

    private static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX")).lowercased()
        return folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func jaroWinkler(_ left: String, _ right: String) -> Double {
        let a = Array(left), b = Array(right)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let distance = max(max(a.count, b.count) / 2 - 1, 0)
        var aMatched = Array(repeating: false, count: a.count)
        var bMatched = Array(repeating: false, count: b.count)
        var matches = 0
        for i in a.indices {
            let lower = max(0, i - distance)
            let upper = min(b.count - 1, i + distance)
            guard lower <= upper else { continue }
            for j in lower...upper where !bMatched[j] && a[i] == b[j] {
                aMatched[i] = true
                bMatched[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }
        let matchedA = a.indices.filter { aMatched[$0] }.map { a[$0] }
        let matchedB = b.indices.filter { bMatched[$0] }.map { b[$0] }
        let swaps = zip(matchedA, matchedB).filter { $0.0 != $0.1 }.count
        let m = Double(matches)
        let jaro = (m / Double(a.count) + m / Double(b.count) +
                    (m - Double(swaps) / 2) / m) / 3
        let prefix = zip(a.prefix(4), b.prefix(4)).prefix(while: { $0.0 == $0.1 }).count
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    // Rectangular minimum-cost assignment. Rows each receive one unique column.
    static func minimumAssignment(_ costs: [[Double]]) -> [Int] {
        let n = costs.count
        guard n > 0 else { return [] }
        let m = costs[0].count
        precondition(m >= n && costs.allSatisfy { $0.count == m })
        var u = Array(repeating: 0.0, count: n + 1)
        var v = Array(repeating: 0.0, count: m + 1)
        var p = Array(repeating: 0, count: m + 1)
        var way = Array(repeating: 0, count: m + 1)
        for row in 1...n {
            p[0] = row
            var column = 0
            var minimum = Array(repeating: Double.infinity, count: m + 1)
            var used = Array(repeating: false, count: m + 1)
            repeat {
                used[column] = true
                let currentRow = p[column]
                var delta = Double.infinity
                var nextColumn = 0
                for candidate in 1...m where !used[candidate] {
                    let reduced = costs[currentRow - 1][candidate - 1] - u[currentRow] - v[candidate]
                    if reduced < minimum[candidate] {
                        minimum[candidate] = reduced
                        way[candidate] = column
                    }
                    if minimum[candidate] < delta {
                        delta = minimum[candidate]
                        nextColumn = candidate
                    }
                }
                for candidate in 0...m {
                    if used[candidate] { u[p[candidate]] += delta; v[candidate] -= delta }
                    else { minimum[candidate] -= delta }
                }
                column = nextColumn
            } while p[column] != 0
            repeat {
                let previous = way[column]
                p[column] = p[previous]
                column = previous
            } while column != 0
        }
        var result = Array(repeating: -1, count: n)
        for column in 1...m where p[column] != 0 { result[p[column] - 1] = column - 1 }
        return result
    }
}
