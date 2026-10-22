import Foundation
import Testing
@testable import LedgerlyDomain

struct ReceiptZoneTests {
    private func parse(_ text: String, zone: String = "Asia/Colombo") -> ReceiptSuggestions {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
        return ReceiptTextParser.parse([text], asOf: Date(timeIntervalSince1970: 1_795_000_000), calendar: calendar)
    }

    @Test func isoOffsetUTCAndGMTReadTheSameInstantAcrossDeviceTimezones() throws {
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-09-19T06:08:06Z"))
        for zone in ["Asia/Colombo", "America/New_York", "Pacific/Auckland"] {
            for text in ["2026-09-19T11:38:06+05:30", "19 Sep 2026 Time:11:38:06 GMT+0530",
                         "19 Sep 2026 06:08:06Z", "19 Sep 2026 06:08:06 UTC"] {
                let result = parse(text, zone: zone)
                #expect(result.dateIncludesTime, "\(text) in \(zone)")
                #expect(result.date == expected, "\(text) in \(zone)")
            }
        }
    }

    @Test func negativeOffsetAndFractionalSecondsPreserveTheInstantAndDayRollover() throws {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = try #require(formatter.date(from: "2026-09-20T03:30:06.125Z"))
        let result = parse("2026-09-19T23:30:06.125-04:00")
        #expect(result.dateIncludesTime)
        let actual = try #require(result.date)
        #expect(abs(actual.timeIntervalSince(expected)) < 0.0001)
    }

    @Test func ambiguousDateOrdersReceiveTheExplicitZoneWithoutInventingAbbreviations() {
        let result = parse("26-09-19 Time:11:38:06+05:30")
        #expect(result.date == nil && result.dateCandidates.count >= 2)
        #expect(result.dateCandidates.allSatisfy { $0.includesTime })
        for text in ["19 Sep 2026 11:38 IST", "19 Sep 2026 11:38+14:30", "19 Sep 2026 11:38+25:00"] {
            #expect(!parse(text).dateIncludesTime)
        }
    }
}
