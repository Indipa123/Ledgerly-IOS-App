import Foundation
import Testing
@testable import LedgerlyDomain

struct ReceiptTextParserTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Colombo")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test func dottedAndSpacedSeparatorsAndShortIsoDaysAreRecognized() {
        for text in ["19.09.2026", "2026.09.19", "2026 / 9 / 19", "19 - 9 - 2026"] {
            let result = ReceiptTextParser.parse([text], calendar: calendar)
            #expect(result.date == day(2026, 9, 19), "\(text)")
            #expect(result.dateCandidates.count == 1)
            #expect(result.dateCandidates.first?.sourceText == text)
        }
        #expect(ReceiptTextParser.parse(["2026/9/9"], calendar: calendar).date == day(2026, 9, 9))
        #expect(ReceiptTextParser.parse(["19/09-2026"], calendar: calendar).dateCandidates.isEmpty)
        #expect(ReceiptTextParser.parse(["19/09/6"], calendar: calendar).dateCandidates.isEmpty)
    }

    @Test func englishMonthNamesAbbreviationsOrdinalsAndTwoDigitYearsAreRecognized() {
        for text in ["19 September 2026", "19 SEP 2026", "19 Sept. 2026", "19-SEP-26",
                     "September 19, 2026", "Sep. 19th, 26", "2026 September 19"] {
            let result = ReceiptTextParser.parse([text], asOf: day(2026, 10, 21), calendar: calendar)
            #expect(result.date == day(2026, 9, 19), "\(text)")
            #expect(result.dateCandidates.count == 1, "\(text)")
        }
        #expect(ReceiptTextParser.parse(["19 Septemberish 2026"], calendar: calendar).dateCandidates.isEmpty)
    }

    @Test func allPrintedPurchaseDatesAreReviewedAndDuplicatesCollapse() {
        let result = ReceiptTextParser.parse(["Invoice: 2026-09-19 Paid: 2026-09-20", "19 Sep 2026"],
                                            asOf: day(2026, 10, 21), calendar: calendar)
        #expect(result.date == nil)
        #expect(Set(result.dateCandidates.map(\.date)) == [day(2026, 9, 19), day(2026, 9, 20)])
        #expect(result.dateCandidates.count == 2)
        let duplicate = ReceiptTextParser.parse(["2026-09-19", "19.09.2026", "September 19, 2026"], calendar: calendar)
        #expect(duplicate.dateCandidates.count == 1 && duplicate.date == day(2026, 9, 19))
    }

    @Test func labelledExpiryDatesDoNotReplaceThePurchaseAndInvalidFirstMatchDoesNotHideLaterDates() {
        let result = ReceiptTextParser.parse(["Expiry: 2027-01-01", "Best before 20 Sep 2027", "Use by 2027/01/02",
            "Valid until 2027.01.03", "Printed 31/02/2026 Purchased 2026-09-19"], calendar: calendar)
        #expect(result.dateCandidates.count == 1 && result.date == day(2026, 9, 19))
    }

    @Test func invalidDaysAndLeapYearsAreCheckedWithoutCalendarRollover() {
        for text in ["29 Feb 2026", "31 April 2026", "2026.02.30", "2026/13/19", "2101-09-19"] {
            #expect(ReceiptTextParser.parse([text], calendar: calendar).dateCandidates.isEmpty, "\(text)")
        }
        #expect(ReceiptTextParser.parse(["29 February 2024"], calendar: calendar).date == day(2024, 2, 29))
    }

    @Test func twoDigitYearsUseGregorianReferenceEvenWhenDeviceCalendarIsBuddhist() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = calendar.timeZone
        let result = ReceiptTextParser.parse(["D:26-09-19 T:11:38:06"], asOf: day(2026, 10, 21), calendar: buddhist)
        #expect(result.date == nil)
        #expect(result.dateCandidates.first?.date == calendar.date(from:
            DateComponents(year: 2026, month: 9, day: 19, hour: 11, minute: 38, second: 6)))
        #expect(result.dateCandidates.first?.format == "YY-MM-DD")
        #expect(result.dateCandidates.contains { calendar.isDate($0.date, inSameDayAs: day(2019, 9, 26)) })
    }

    @Test func printedDateAboveMerchantIsNotUsedAsMerchant() {
        let result = ReceiptTextParser.parse(["Expiry: 2027-01-01", "19 Sep 2026", "Synthetic Cafe", "TOTAL 430.00"], calendar: calendar)
        #expect(result.merchant == "Synthetic Cafe")
        #expect(result.amount == 430)
    }

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
