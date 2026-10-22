import Foundation
import Testing
@testable import LedgerlyDomain

struct ReconciliationTests {
    @Test func csvReadsDebitCreditAndQuotedMerchantWithoutGuessingBadRows() throws {
        let csv = "Date,Description,Debit,Credit\n" +
            "19/09/2026,\"Digital, TECHLABS\",430.00,\n" +
            "20/09/2026,Salary,,150000.00\n" +
            "26-09-19,Ambiguous old date,50.00,\n"
        let parsed = try StatementParser.csv(Data(csv.utf8))
        #expect(parsed.lines.count == 2)
        #expect(parsed.lines[0].description == "Digital, TECHLABS")
        #expect(parsed.lines[0].kind == .expense)
        #expect(parsed.lines[0].amount == 430)
        #expect(parsed.lines[1].kind == .income)
        #expect(parsed.skippedRows == 1)
    }

    @Test func signedAmountLayoutAndTwoPdfTextLayouts() throws {
        let csv = "Posted Date,Details,Amount,Type\n2026-09-19,Bus ticket,-430.00,DR\n2026-09-20,Salary,150000.00,CR\n"
        let parsed = try StatementParser.csv(Data(csv.utf8))
        #expect(parsed.lines.map(\.kind) == [.expense, .income])
        let pdf = "19/09/2026 Bus ticket 430.00 DR\n2026-09-20 Salary 0.00 150000.00\n"
        let extracted = try StatementParser.pdfText(pdf)
        #expect(extracted.lines.count == 2)
        #expect(extracted.lines.map(\.kind) == [.expense, .income])
        #expect(throws: StatementParseError.self) { try StatementParser.pdfText("   ") }
        #expect(throws: StatementParseError.self) {
            try StatementParser.csv(Data("Date,Description,Amount\n2026-09-19,Ambiguous,430.00\n".utf8))
        }
    }

    @Test func rectangularAssignmentFindsGlobalOptimumRatherThanGreedyChoice() {
        let assignment = ReconciliationMatcher.minimumAssignment([[1, 2, 10], [1.1, 100, 10]])
        #expect(assignment == [1, 0])
    }

    @Test func duplicateAmountsStillMatchOneToOneAndExplainConflicts() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let uber = LedgerEntry(id: UUID(), kind: .expense, amount: 500,
                               title: "Uber Eats", category: "Food & Drink", date: date, note: "")
        let uberSecond = LedgerEntry(id: UUID(), kind: .expense, amount: 500,
                                     title: "Uber Eats", category: "Food & Drink", date: date, note: "")
        let salary = LedgerEntry(id: UUID(), kind: .income, amount: 4_800,
                                 title: "Salary", category: "Salary", date: date, note: "")
        let lines = [StatementLine(id: 1, date: date, description: "UBER EATS", kind: .expense, amount: 500),
                     StatementLine(id: 2, date: date, description: "UBER EATS", kind: .expense, amount: 500),
                     StatementLine(id: 3, date: date, description: "Salary", kind: .income, amount: 5_000),
                     StatementLine(id: 4, date: date, description: "Unrelated", kind: .expense, amount: 500)]
        let result = ReconciliationMatcher.compare(lines, with: [uber, uberSecond, salary])
        #expect(result.matched.count == 2)
        #expect(Set(result.matched.map(\.entry.id)).count == 2)
        #expect(result.amountConflicts.count == 1)
        #expect(result.amountConflicts[0].statement.id == 3)
        #expect(result.amountConflicts[0].explanation.contains("Amount differs"))
        #expect(result.missingInApp.map(\.id) == [4])
        #expect(result.missingOnStatement.isEmpty)
    }

    @Test func unmatchedAppEntryAndWrongKindRemainSeparate() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let expense = LedgerEntry(id: UUID(), kind: .expense, amount: 250,
                                  title: "Taxi", category: "Transport", date: date, note: "")
        let line = StatementLine(id: 1, date: date, description: "Taxi", kind: .income, amount: 250)
        let result = ReconciliationMatcher.compare([line], with: [expense])
        #expect(result.missingInApp.count == 1)
        #expect(result.missingOnStatement.map(\.id) == [expense.id])
    }

    @Test func labelledDuplicateAmountFixtureBeatsNearestAmountBaseline() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let taxi = LedgerEntry(id: UUID(), kind: .expense, amount: 100,
                               title: "Taxi", category: "Transport", date: date, note: "")
        let uber = LedgerEntry(id: UUID(), kind: .expense, amount: 100,
                               title: "Uber", category: "Transport", date: date, note: "")
        let salary = LedgerEntry(id: UUID(), kind: .income, amount: 200,
                                 title: "Salary", category: "Salary", date: date, note: "")
        let lines = [StatementLine(id: 1, date: date, description: "Uber", kind: .expense, amount: 100),
                     StatementLine(id: 2, date: date, description: "Taxi", kind: .expense, amount: 100),
                     StatementLine(id: 3, date: date, description: "Salary", kind: .income, amount: 210),
                     StatementLine(id: 4, date: date, description: "Unknown", kind: .expense, amount: 50)]
        let expected = [1: uber.id, 2: taxi.id, 3: salary.id]
        let result = ReconciliationMatcher.compare(lines, with: [taxi, uber, salary])
        let proposed = result.matched.map { ($0.statement.id, $0.entry.id) } +
            result.amountConflicts.map { ($0.statement.id, $0.entry.id) }
        let correct = proposed.filter { expected[$0.0] == $0.1 }.count
        #expect(correct == 3)
        #expect(result.missingInApp.map(\.id) == [4])

        // A one-to-one nearest-amount baseline takes the first equal amount it sees.
        var unused = [taxi, uber, salary]
        var greedyCorrect = 0
        for line in lines {
            guard let index = unused.indices.filter({ unused[$0].kind == line.kind }).min(by: {
                abs(unused[$0].amount - line.amount) < abs(unused[$1].amount - line.amount)
            }) else { continue }
            let chosen = unused.remove(at: index)
            if expected[line.id] == chosen.id { greedyCorrect += 1 }
        }
        #expect(greedyCorrect == 1)
    }
}
