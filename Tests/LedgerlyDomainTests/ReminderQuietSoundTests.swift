import Foundation
import Testing
@testable import LedgerlyDomain

struct ReminderQuietSoundTests {
    private func withPreferences(_ body: (inout BudgetAlertPreferences, UserDefaults) throws -> Void) throws {
        let name = "ledgerly-reminder-sound-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var preferences = BudgetAlertPreferences(defaults: defaults)
        try body(&preferences, defaults)
    }

    @Test func oldPreferencesKeepReminderSoundsAndChoicePersistsIndependently() throws {
        try withPreferences { preferences, defaults in
            #expect(!preferences.quietReminderSounds)
            preferences.monthlyEnabled = false
            preferences.categoryEnabled = true
            preferences.quietHours = .init(enabled: true)
            #expect(!preferences.silencesReminder(hour: 23, minute: 0))
            preferences.quietReminderSounds = true
            preferences.save(to: defaults)
            #expect(BudgetAlertPreferences(defaults: defaults) == preferences)
            #expect(!preferences.monthlyEnabled && preferences.categoryEnabled)
            preferences.quietHours.enabled = false
            #expect(!preferences.silencesReminder(hour: 23, minute: 0))
        }
    }

    @Test func overnightAndDaytimeWindowsIncludeStartAndExcludeEnd() throws {
        try withPreferences { preferences, _ in
            preferences.quietReminderSounds = true
            preferences.quietHours = .init(enabled: true)
            #expect(!preferences.silencesReminder(hour: 21, minute: 59))
            #expect(preferences.silencesReminder(hour: 22, minute: 0))
            #expect(preferences.silencesReminder(hour: 0, minute: 0))
            #expect(preferences.silencesReminder(hour: 7, minute: 59))
            #expect(!preferences.silencesReminder(hour: 8, minute: 0))
            preferences.quietHours = .init(enabled: true, startMinute: 9 * 60, endMinute: 17 * 60)
            #expect(preferences.silencesReminder(hour: 9, minute: 0))
            #expect(preferences.silencesReminder(hour: 16, minute: 59))
            #expect(!preferences.silencesReminder(hour: 17, minute: 0))
        }
    }

    @Test func invalidHoursAndClockValuesCannotSilenceAllReminders() throws {
        try withPreferences { preferences, _ in
            preferences.quietReminderSounds = true
            preferences.quietHours = .init(enabled: true)
            for (hour, minute) in [(-1, 0), (24, 0), (23, -1), (23, 60)] {
                #expect(!preferences.silencesReminder(hour: hour, minute: minute))
            }
            preferences.quietHours = .init(enabled: true, startMinute: 0, endMinute: 0)
            #expect(!preferences.silencesReminder(hour: 0, minute: 0))
            preferences.quietHours = .init(enabled: true, startMinute: -1, endMinute: 480)
            #expect(!preferences.silencesReminder(hour: 0, minute: 0))
        }
    }

    @Test func snoozeChecksDeliveryDateInTheSuppliedLocalTimezoneAcrossDST() throws {
        try withPreferences { preferences, _ in
            preferences.quietReminderSounds = true
            preferences.quietHours = .init(enabled: true, startMinute: 23 * 60, endMinute: 90)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York")!
            let parse = ISO8601DateFormatter()
            #expect(preferences.silencesReminder(at: parse.date(from: "2026-11-01T01:15:00-04:00")!, calendar: calendar))
            #expect(preferences.silencesReminder(at: parse.date(from: "2026-11-01T01:15:00-05:00")!, calendar: calendar))
            #expect(!preferences.silencesReminder(at: parse.date(from: "2026-11-01T01:30:00-05:00")!, calendar: calendar))
            calendar.timeZone = TimeZone(identifier: "Asia/Colombo")!
            #expect(!preferences.silencesReminder(at: parse.date(from: "2026-11-01T01:15:00-05:00")!, calendar: calendar))
        }
    }

    @Test func pendingSelectionIncludesOnlyExactOwnerRemindersAndTheirSnoozes() {
        let id = UUID().uuidString
        #expect(ReminderNotificationIdentity.belongsToOwner("reminder.owner.\(id)", owner: "owner"))
        #expect(ReminderNotificationIdentity.belongsToOwner("reminder.owner.\(id).snooze", owner: "owner"))
        #expect(ReminderNotificationIdentity.belongsToOwner("reminder.owner.\(id).snooze.snooze", owner: "owner"))
        for identifier in ["reminder.other.\(id)", "reminder.owner2.\(id)", "reminder.owner.123",
                           "reminder.owner.\(id).", "reminder.owner.\(id).other", "place.owner.\(id)",
                           "ledgerly.notification.deliveryTest", "ledgerly.budgetAlert.owner.warning"] {
            #expect(!ReminderNotificationIdentity.belongsToOwner(identifier, owner: "owner"))
        }
    }
}
