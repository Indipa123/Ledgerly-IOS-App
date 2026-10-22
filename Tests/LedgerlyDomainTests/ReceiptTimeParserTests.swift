import Foundation
import Testing
@testable import LedgerlyDomain

struct ReceiptTimeParserTests {
    private func calendar(_ zone: String = "Asia/Colombo") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func parsed(_ lines: [String], zone: String = "Asia/Colombo") -> ReceiptSuggestions {
        ReceiptTextParser.parse(lines, asOf: Date(timeIntervalSince1970: 1_792_540_800), calendar: calendar(zone))
    }

    @Test func twentyFourHourTimePreservesHoursMinutesSecondsAndSource() throws {
        let result = parsed(["19 Sep 2026 T:11:38:06"])
        let date = try #require(result.date)
        let parts = calendar().dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(parts.year == 2026 && parts.month == 9 && parts.day == 19)
        #expect(parts.hour == 11 && parts.minute == 38 && parts.second == 6)
        #expect(result.dateIncludesTime)
        #expect(result.dateCandidates.first?.timeSourceText == "11:38:06")
    }

    @Test func twelveHourClocksHandleNoonMidnightDottedMeridiemAndHourOnly() throws {
        for (text, hour, minute) in [("12:00 AM", 0, 0), ("12:00 PM", 12, 0),
            ("8:30 p.m.", 20, 30), ("8:30AM", 8, 30), ("8 PM", 20, 0), ("00:15", 0, 15)] {
            let result = parsed(["19 Sep 2026 Time: \(text)"])
            let date = try #require(result.date, "\(text)")
            let parts = calendar().dateComponents([.hour, .minute], from: date)
            #expect(result.dateIncludesTime, "\(text)")
            #expect(parts.hour == hour && parts.minute == minute, "\(text)")
        }
    }

    @Test func onlyClearNextLineTimesAttachToTheDateAndNoDateIsInvented() throws {
        for next in ["Time: 11:38:06", "T:11:38:06", "11:38:06"] {
            let result = parsed(["19 Sep 2026", next])
            #expect(result.dateIncludesTime)
            #expect(calendar().component(.hour, from: try #require(result.date)) == 11)
        }
        for next in ["Cashier 11:38:06", "Expiry Time: 11:38:06"] {
            #expect(!parsed(["19 Sep 2026", next]).dateIncludesTime)
        }
        let noDate = parsed(["Time: 11:38:06"])
        #expect(noDate.date == nil && noDate.dateCandidates.isEmpty && noDate.merchant == nil)
    }

    @Test func competingTimesAndDifferentDateTokensRemainReviewChoices() {
        let times = parsed(["19 Sep 2026 Opened 10:00 Paid 11:30"])
        #expect(times.date == nil && times.dateCandidates.count == 2)
        #expect(times.dateCandidates.allSatisfy { $0.includesTime })
        let dates = parsed(["19 Sep 2026 / 20 Sep 2026 11:30"])
        #expect(dates.date == nil && dates.dateCandidates.count == 2)
        #expect(dates.dateCandidates.allSatisfy { !$0.includesTime })
    }

    @Test func duplicateDateHeadersDoNotErasePreciseTimeOrCreateExtraChoices() throws {
        let result = parsed(["2026-09-19", "19 Sep 2026 Time:11:38:06", "19.09.2026",
                             "19 Sep 2026 Time:11:38:06"])
        #expect(result.dateCandidates.count == 1 && result.dateIncludesTime)
        #expect(calendar().component(.hour, from: try #require(result.date)) == 11)
    }

    @Test func invalidOrAmbiguousZoneClocksAreLeftForManualEntry() {
        for time in ["24:00", "12:60", "12:30:60", "00:30 AM", "13:30 PM", "12:300", "012:30",
                     "11:38:06+25:00", "11:38:06+05:75", "11:38 IST"] {
            let result = parsed(["19 Sep 2026 Time: \(time)"])
            #expect(!result.dateIncludesTime, "\(time)")
            #expect(result.dateCandidates.count == 1, "\(time)")
        }
    }

    @Test func missingSpringClockIsNotShiftedAndRepeatedFallClockOffersBothInstants() throws {
        let missing = parsed(["2026-03-08 Time:02:30:00"], zone: "America/New_York")
        #expect(!missing.dateIncludesTime && missing.dateCandidates.count == 1)
        let repeated = parsed(["2026-11-01 Time:01:30:00"], zone: "America/New_York")
        #expect(repeated.date == nil && repeated.dateCandidates.count == 2)
        #expect(repeated.dateCandidates.allSatisfy { $0.includesTime })
        let sorted = repeated.dateCandidates.map(\.date).sorted()
        #expect(try #require(sorted.last).timeIntervalSince(#require(sorted.first)) == 3_600)
    }

    @Test func busTicketKeepsDateOrderChoicesWithThePrintedClock() {
        let result = parsed(["D:26-09-19 T:11:38:06"])
        #expect(result.date == nil && result.dateCandidates.count == 2)
        #expect(result.dateCandidates.allSatisfy { $0.includesTime })
        #expect(result.dateCandidates.allSatisfy { calendar().component(.second, from: $0.date) == 6 })
    }

    @Test func dateOnlyImportPreservesEditorClockAndExplicitTimeImportsTheExactInstant() throws {
        let calendar = calendar()
        let editorDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21,
            hour: 20, minute: 42, second: 17)))
        let receiptDate = try #require(parsed(["19 Sep 2026 Time:11:38:06"]).date)
        let dateOnly = ReceiptDateSelection.applying(receiptDate, includesTime: false, to: editorDate, calendar: calendar)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: dateOnly)
        #expect(parts.year == 2026 && parts.month == 9 && parts.day == 19)
        #expect(parts.hour == 20 && parts.minute == 42 && parts.second == 17)
        #expect(ReceiptDateSelection.applying(receiptDate, includesTime: true, to: editorDate, calendar: calendar) == receiptDate)
    }
}
