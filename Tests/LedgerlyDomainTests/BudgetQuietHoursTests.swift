import Foundation
import Testing
@testable import LedgerlyDomain

struct BudgetQuietHoursTests {
    private func calendar(_ zone: String = "Asia/Colombo") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func overnightWarningsWaitUntilMorningInLocalTime() {
        let hours = BudgetQuietHours(enabled: true)
        let night = date("2026-10-18T23:20:00+05:30")
        #expect(hours.deliveryDate(after: night, calendar: calendar()) == date("2026-10-19T08:00:00+05:30"))
        let morning = date("2026-10-19T02:00:00+05:30")
        #expect(hours.deliveryDate(after: morning, calendar: calendar()) == date("2026-10-19T08:00:00+05:30"))
        #expect(hours.deliveryDate(after: night, calendar: calendar("UTC")) == night.addingTimeInterval(1))
    }

    @Test func daytimeScheduleAndEndBoundary() {
        let hours = BudgetQuietHours(enabled: true, startMinute: 9 * 60, endMinute: 17 * 60)
        let during = date("2026-10-18T12:00:00+05:30")
        #expect(hours.deliveryDate(after: during, calendar: calendar()) == date("2026-10-18T17:00:00+05:30"))
        let end = date("2026-10-18T17:00:00+05:30")
        #expect(!hours.contains(end, calendar: calendar()))
        #expect(hours.deliveryDate(after: end, calendar: calendar()) == end.addingTimeInterval(1))
    }

    @Test func pendingOneSecondAlertDoesNotCrossIntoQuietHours() {
        var hours = BudgetQuietHours(enabled: true)
        let before = date("2026-10-18T21:59:59+05:30")
        #expect(hours.deliveryDate(after: before, calendar: calendar()) == date("2026-10-19T08:00:00+05:30"))
        #expect(hours.contains(date("2026-10-18T22:00:00+05:30"), calendar: calendar()))
        hours.enabled = false
        #expect(hours.deliveryDate(after: before, calendar: calendar()) == before.addingTimeInterval(1))
    }

    @Test func daylightSavingMissingAndRepeatedEndTimes() {
        let zone = calendar("America/New_York")
        let spring = BudgetQuietHours(enabled: true, startMinute: 23 * 60, endMinute: 2 * 60 + 30)
        #expect(spring.deliveryDate(after: date("2026-03-08T01:00:00-05:00"), calendar: zone) ==
                date("2026-03-08T03:00:00-04:00"))
        let fall = BudgetQuietHours(enabled: true, startMinute: 23 * 60, endMinute: 90)
        #expect(fall.deliveryDate(after: date("2026-11-01T01:15:00-04:00"), calendar: zone) ==
                date("2026-11-01T01:30:00-05:00"))
    }

    @Test func savedScheduleSurvivesReopeningWithoutChangingAlertChoices() throws {
        let name = "ledgerly-quiet-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var preferences = BudgetAlertPreferences(defaults: defaults)
        preferences.monthlyEnabled = true
        preferences.categoryEnabled = false
        preferences.quietHours = BudgetQuietHours(enabled: true, startMinute: 21 * 60, endMinute: 7 * 60 + 30)
        preferences.save(to: defaults)
        #expect(BudgetAlertPreferences(defaults: defaults) == preferences)
    }

    @Test func invalidStoredHoursFallBackToDisabledDefaults() throws {
        let name = "ledgerly-quiet-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for hours in [BudgetQuietHours(enabled: true, startMinute: 60, endMinute: 60),
                      BudgetQuietHours(enabled: true, startMinute: -1, endMinute: 480)] {
            defaults.set(try JSONEncoder().encode(hours), forKey: "ledgerly.notifications.budgetQuietHours")
            #expect(BudgetAlertPreferences(defaults: defaults).quietHours == BudgetQuietHours())
        }
    }
}
