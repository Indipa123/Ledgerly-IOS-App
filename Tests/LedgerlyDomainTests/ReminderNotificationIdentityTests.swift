import Foundation
import Testing
@testable import LedgerlyDomain

struct ReminderNotificationIdentityTests {
    @Test func repeatedSnoozesUseOneStableRequestAndKeepOwnerAndReminderIdentity() throws {
        let id = UUID()
        let base = "reminder.owner.\(id.uuidString)"
        let canonical = base + ".snooze"
        for depth in 0...25 {
            let source = base + String(repeating: ".snooze", count: depth)
            #expect(ReminderNotificationIdentity.snoozeIdentifier(source, owner: "owner") == canonical)
            #expect(ReminderNotificationIdentity.reminderID(source, owner: "owner") == id)
        }
        #expect(ReminderNotificationIdentity.snoozeIdentifier(base, owner: "other") == nil)
        #expect(ReminderNotificationIdentity.snoozeIdentifier("place.owner.\(id)", owner: "owner") == nil)
        #expect(ReminderNotificationIdentity.snoozeIdentifier(base + ".unknown", owner: "owner") == nil)
    }

    @Test func legacyCleanupCannotCancelAFreshCanonicalOrRegularRequest() {
        let id = UUID()
        let base = "reminder.owner.\(id)"
        let canonical = base + ".snooze"
        let old = [canonical + ".snooze", canonical + ".snooze.snooze"]
        let unrelated = ["reminder.other.\(id).snooze.snooze",
                         "reminder.owner.\(UUID()).snooze.snooze", "ledgerly.notification.deliveryTest"]
        let pending = [base, canonical] + old + unrelated
        #expect(ReminderNotificationIdentity.snoozeIdentifiers(in: pending, reminderID: id,
            owner: "owner", legacyOnly: true) == old)
        #expect(ReminderNotificationIdentity.snoozeIdentifiers(in: pending, reminderID: id,
            owner: "owner") == [canonical] + old)
    }

    @MainActor @Test func deletedPausedAndOtherAccountRemindersCannotHandleActions() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        var reminder = LedgerReminder(id: UUID(), title: "Synthetic bill", amount: 50,
            frequency: .monthly, dayOfMonth: 1, weekday: 2, date: .now, hour: 9, minute: 0, isPaused: false)
        let identifier = "reminder.owner.\(reminder.id).snooze.snooze"
        try repository.saveReminder(reminder)
        #expect(try ReminderNotificationIdentity.activeReminder(identifier, owner: "owner",
            reminders: repository.fetchReminders())?.id == reminder.id)
        #expect(try ReminderNotificationIdentity.activeReminder(identifier, owner: "other",
            reminders: repository.fetchReminders()) == nil)
        reminder.isPaused = true
        try repository.saveReminder(reminder)
        #expect(try ReminderNotificationIdentity.activeReminder(identifier, owner: "owner",
            reminders: repository.fetchReminders()) == nil)
        try repository.deleteReminder(id: reminder.id)
        #expect(try ReminderNotificationIdentity.activeReminder(identifier, owner: "owner",
            reminders: repository.fetchReminders()) == nil)
    }

    @Test func deliveredOneTimeRemindersRemainSnoozableWithoutInventingANewRegularSchedule() {
        let reminder = LedgerReminder(id: UUID(), title: "Past one-time payment", amount: nil,
            frequency: .once, dayOfMonth: 1, weekday: 2, date: Date(timeIntervalSince1970: 0),
            hour: 9, minute: 0, isPaused: false)
        #expect(reminder.nextOccurrence() == nil)
        let identifier = "reminder.guest.\(reminder.id)"
        #expect(ReminderNotificationIdentity.activeReminder(identifier, owner: "guest", reminders: [reminder])?.id == reminder.id)
        #expect(ReminderNotificationIdentity.activeReminder(identifier, owner: "signed-in", reminders: [reminder]) == nil)
    }
}
