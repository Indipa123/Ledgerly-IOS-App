import Foundation
import Testing
@testable import LedgerlyDomain

struct ReceiptTextParserTests {
    @Test func choosesGrandTotalInsteadOfSubtotal() {
        let result = ReceiptTextParser.parse([
            "KEELLS SUPER", "Date 03/10/2026", "Subtotal Rs 1,150.00",
            "Tax Rs 50.00", "Grand Total Rs 1,200.00", "Cash Rs 2,000.00"
        ])
        #expect(result.merchant == "KEELLS SUPER")
        #expect(result.amount == Decimal(string: "1200.00"))
        #expect(result.date == nil)
        #expect(result.dateCandidates.count == 2)
    }

    @Test func unreadableReceiptKeepsManualPathOpen() {
        let result = ReceiptTextParser.parse(["", "   "])
        #expect(result.merchant == nil)
        #expect(result.amount == nil)
        #expect(result.date == nil)
    }

    @Test func readsDateAndTotalFromBusTicket() {
        let reference = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 3))!
        let result = ReceiptTextParser.parse([
            "Negambo", "BN:NB-SLTB Luxury", "D:26-09-19 T:11:38:06",
            "FULL: 1 * 430.00 = 430.00", "TOTAL : Rs.430.00"
        ], asOf: reference)
        #expect(result.amount == 430)
        #expect(result.date == nil)
        #expect(result.dateCandidates.first?.format == "YY-MM-DD")
        let components = Calendar.current.dateComponents([.day, .month, .year], from: result.dateCandidates[0].date)
        #expect(components.day == 19)
        #expect(components.month == 9)
        #expect(components.year == 2026)
    }

    @Test func unambiguousStylesAreSuggestedDirectly() {
        let dayFirst = ReceiptTextParser.parse(["19/09/2026"])
        #expect(dayFirst.dateCandidates.count == 1)
        #expect(dayFirst.dateCandidates.first?.format == "DD-MM-YYYY")
        let monthFirst = ReceiptTextParser.parse(["09/19/2026"])
        #expect(monthFirst.dateCandidates.count == 1)
        #expect(monthFirst.dateCandidates.first?.format == "MM-DD-YYYY")
        let iso = ReceiptTextParser.parse(["2026-09-19"])
        #expect(iso.dateCandidates.count == 1)
        #expect(iso.dateCandidates.first?.format == "YYYY-MM-DD")
    }
}
