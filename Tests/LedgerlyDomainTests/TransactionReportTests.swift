import Foundation
import Testing
@testable import LedgerlyDomain

struct TransactionReportTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func includesTheEntireEndDayAndKeepsExactAmounts() {
        let first = entry(.income, "Salary", amount: "1000.25", day: 1, hour: 0)
        let last = entry(.expense, "Groceries", amount: "250.10", day: 15, hour: 23)
        let outside = entry(.expense, "Transport", amount: "5", day: 16, hour: 0)
        let report = TransactionReport(entries: [outside, last, first],
                                       startDay: first.date, endDay: last.date, calendar: calendar)
        #expect(report?.entries.map(\.id) == [last.id, first.id])
        #expect(report?.income == Decimal(string: "1000.25"))
        #expect(report?.expense == Decimal(string: "250.10"))
        #expect(report?.net == Decimal(string: "750.15"))
        #expect(report?.expenseByCategory.first?.name == "Groceries")
        #expect(TransactionReport(entries: [], startDay: last.date,
                                  endDay: first.date, calendar: calendar)?.startDay == nil)
    }

    @Test func csvEscapesUserTextAndRequiresLocationOptIn() throws {
        var payment = LedgerEntry(id: UUID(), kind: .expense, amount: Decimal(string: "12.34")!,
                                  title: "=HYPERLINK(\"bad\")", category: "Food, Drink",
                                  date: date(day: 15, hour: 12), note: "Line one\nLine two")
        payment.location = LedgerLocation(placeID: nil, name: "Shop", latitude: 6.9, longitude: 79.8)
        let report = try #require(TransactionReport(entries: [payment],
                                                    startDay: date(day: 15, hour: 0),
                                                    endDay: date(day: 15, hour: 0), calendar: calendar))

        let privateCSV = report.csv(paymentMethods: [], timeZone: calendar.timeZone)
        #expect(privateCSV.contains("\"'=HYPERLINK(\"\"bad\"\")\""))
        #expect(privateCSV.contains("\"Food, Drink\""))
        #expect(privateCSV.contains("\"Line one\nLine two\""))
        #expect(privateCSV.contains("\"12.34\""))
        #expect(!privateCSV.contains("Shop"))
        #expect(!privateCSV.contains("Latitude"))

        let withLocation = report.csv(paymentMethods: [], includeLocations: true,
                                      timeZone: calendar.timeZone)
        #expect(withLocation.contains("\"Place\",\"Latitude\",\"Longitude\""))
        #expect(withLocation.contains("\"Shop\",\"6.9\",\"79.8\""))
    }

    private func entry(_ kind: EntryKind, _ category: String, amount: String,
                       day: Int, hour: Int) -> LedgerEntry {
        LedgerEntry(id: UUID(), kind: kind, amount: Decimal(string: amount)!,
                    title: category, category: category, date: date(day: day, hour: hour), note: "")
    }

    private func date(day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
}
