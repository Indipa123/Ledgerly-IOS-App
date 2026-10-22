import Foundation
import Testing
@testable import LedgerlyDomain

struct PlaceArrivalPolicyTests {
    @Test func radiusAndRegionLimit() {
        #expect(PlaceArrivalPolicy.radius(5) == 50)
        #expect(PlaceArrivalPolicy.radius(250) == 250)
        #expect(PlaceArrivalPolicy.radius(900) == 500)
        let places = (0..<23).map {
            LedgerPlace(id: UUID(), name: "Place \($0)", latitude: 7, longitude: 80)
        }
        let active = PlaceArrivalPolicy.activePlaces(places, enabledIDs: Set(places.map(\.id)))
        #expect(active.count == 20)
        #expect(PlaceArrivalPolicy.activePlaces(places, enabledIDs: []).isEmpty)
    }

    @Test func arrivalCooldown() {
        let id = UUID()
        let now = Date()
        #expect(PlaceArrivalPolicy.shouldPrompt(placeID: id, now: now, lastPrompt: nil, entries: []))
        #expect(!PlaceArrivalPolicy.shouldPrompt(placeID: id, now: now,
                                                 lastPrompt: now.addingTimeInterval(-60), entries: []))
        #expect(PlaceArrivalPolicy.shouldPrompt(placeID: id, now: now,
                                                lastPrompt: now.addingTimeInterval(-31 * 60), entries: []))
        let expense = LedgerEntry(id: UUID(), kind: .expense, amount: 430,
                                  title: "Bus fare", category: "Transport",
                                  date: now.addingTimeInterval(-5 * 60), note: "",
                                  location: LedgerLocation(placeID: id, name: "Bus station",
                                                           latitude: 7, longitude: 80))
        #expect(!PlaceArrivalPolicy.shouldPrompt(placeID: id, now: now,
                                                 lastPrompt: nil, entries: [expense]))
        #expect(PlaceArrivalPolicy.shouldPrompt(placeID: UUID(), now: now,
                                                lastPrompt: nil, entries: [expense]))
    }

    @Test func mutingSuppressesAnOtherwiseEligibleArrival() {
        let id = UUID()
        #expect(PlaceArrivalPolicy.shouldPrompt(placeID: id, now: .now, lastPrompt: nil, entries: []))
        #expect(!PlaceArrivalPolicy.shouldPrompt(placeID: id, now: .now, lastPrompt: nil,
                                                 entries: [], isMuted: true))
    }

    @Test func overnightQuietHoursIncludeStartAndExcludeEnd() throws {
        let hours = PlaceQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60)
        let calendar = Self.calendar()
        for (hour, minute, expected) in [(21, 59, false), (22, 0, true), (23, 59, true),
                                          (0, 0, true), (7, 59, true), (8, 0, false), (12, 0, false)] {
            let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 17,
                                                                        hour: hour, minute: minute)))
            #expect(hours.contains(date, calendar: calendar) == expected)
            #expect(PlaceArrivalPolicy.shouldPrompt(placeID: UUID(), now: date, lastPrompt: nil,
                entries: [], quietHours: hours, calendar: calendar) == !expected)
        }
    }

    @Test func daytimeQuietHoursAndDisabledSettings() throws {
        var hours = PlaceQuietHours(enabled: true, startMinute: 9 * 60, endMinute: 17 * 60)
        let calendar = Self.calendar()
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 9)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 17)))
        #expect(hours.contains(morning, calendar: calendar))
        #expect(!hours.contains(end, calendar: calendar))
        hours.enabled = false
        #expect(!hours.contains(morning, calendar: calendar))
        #expect(PlaceArrivalPolicy.allowsPrompts(isMuted: false, quietHours: hours, now: morning,
                                                 calendar: calendar))
    }

    @Test func quietHoursFollowDeviceTimeZoneAndSurvivePersistence() throws {
        let hours = PlaceQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60)
        let local = Self.calendar()
        let date = try #require(local.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 22)))
        var utc = local
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        #expect(hours.contains(date, calendar: local))
        #expect(!hours.contains(date, calendar: utc))
        let decoded = try JSONDecoder().decode(PlaceQuietHours.self, from: JSONEncoder().encode(hours))
        #expect(decoded == hours)
    }

    @Test func invalidQuietHoursCannotMuteTheWholeDay() {
        for hours in [PlaceQuietHours(enabled: true, startMinute: 0, endMinute: 0),
                      PlaceQuietHours(enabled: true, startMinute: -1, endMinute: 60),
                      PlaceQuietHours(enabled: true, startMinute: 60, endMinute: 1_440)] {
            #expect(!hours.isValid)
            #expect(!hours.contains(.now))
        }
    }

    private static func calendar() -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Asia/Colombo")!
        return result
    }
}
