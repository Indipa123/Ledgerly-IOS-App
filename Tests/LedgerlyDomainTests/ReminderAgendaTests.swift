import Foundation
import Testing
@testable import LedgerlyDomain

@MainActor
struct ReminderAgendaTests {
    private func calendar(_ zone: String = "Asia/Colombo") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ year: Int = 2026, _ month: Int = 10, _ day: Int = 20,
                      _ hour: Int = 8, _ minute: Int = 0, calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar()).date(from: DateComponents(year: year, month: month,
            day: day, hour: hour, minute: minute))!
    }

    private func reminder(_ title: String = "Bill", frequency: ReminderFrequency = .monthly,
                          day: Int = 20, weekday: Int = 3, hour: Int = 9,
                          paused: Bool = false, id: UUID = UUID()) -> LedgerReminder {
        .init(id: id, title: title, amount: 430, frequency: frequency, dayOfMonth: day,
              weekday: weekday, date: date(), hour: hour, minute: 0, isPaused: paused)
    }

    @Test func monthlyPreviewUsesFutureOccurrencesAcrossMonthsAndYears() {
        let bill = reminder(day: 28)
        #expect(bill.nextOccurrence(after: date(2026, 1, 28, 8), calendar: calendar()) == date(2026, 1, 28, 9))
        #expect(bill.nextOccurrence(after: date(2026, 1, 28, 9), calendar: calendar()) == date(2026, 2, 28, 9))
        #expect(bill.nextOccurrence(after: date(2026, 2, 28, 10), calendar: calendar()) == date(2026, 3, 28, 9))
        #expect(bill.nextOccurrence(after: date(2028, 2, 28, 10), calendar: calendar()) == date(2028, 3, 28, 9))
        #expect(bill.nextOccurrence(after: date(2026, 12, 28, 10), calendar: calendar()) == date(2027, 1, 28, 9))
    }

    @Test func weeklyPreviewUsesWeekdayAndTimeAndAdvancesAfterTheCurrentOccurrence() {
        let bill = reminder(frequency: .weekly, weekday: 3)
        #expect(bill.nextOccurrence(after: date(), calendar: calendar()) == date(2026, 10, 20, 9))
        #expect(bill.nextOccurrence(after: date(2026, 10, 20, 9), calendar: calendar()) == date(2026, 10, 27, 9))
        let sunday = reminder(frequency: .weekly, weekday: 1)
        #expect(sunday.nextOccurrence(after: date(2026, 10, 24, 18), calendar: calendar()) == date(2026, 10, 25, 9))
    }

    @Test func oneTimePreviewKeepsLocalDayAndDoesNotRepeatAnExpiredSchedule() {
        var bill = reminder(frequency: .once)
        // This instant is 20 October in Colombo, but still 19 October in UTC.
        bill.date = ISO8601DateFormatter().date(from: "2026-10-19T20:00:00Z")!
        #expect(bill.dateComponents(calendar: calendar()).day == 20)
        #expect(bill.nextOccurrence(after: date(), calendar: calendar()) == date(2026, 10, 20, 9))
        #expect(bill.nextOccurrence(after: date(2026, 10, 20, 9), calendar: calendar()) == nil)
        #expect(bill.nextOccurrence(after: date(2026, 10, 21, 8), calendar: calendar()) == nil)
        #expect(bill.nextOccurrence(after: date(), calendar: calendar("UTC")) == nil)
    }

    @Test func agendaGroupsPausedAndPastSchedulesAndSortsUpcomingByTimeWithStableTies() {
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let soon = reminder("Z early", hour: 9)
        let later = reminder("A later", hour: 12)
        let tieA = reminder("Same", hour: 10, id: earlierID)
        let tieB = reminder("Same", hour: 10, id: laterID)
        let paused = reminder("Paused", paused: true)
        var past = reminder("Past", frequency: .once)
        past.date = date(2026, 10, 19)
        let input = [past, later, tieB, paused, tieA, soon]
        let items = ReminderAgenda.items(input, asOf: date(), calendar: calendar())
        #expect(items.map(\.id) == [soon.id, tieA.id, tieB.id, later.id, paused.id, past.id])
        #expect(items.map(\.group) == [.upcoming, .upcoming, .upcoming, .upcoming, .paused, .needsAttention])
        past.isPaused = true
        #expect(ReminderAgenda.items([past], asOf: date(), calendar: calendar()).first?.group == .paused)
        #expect(soon.isPaused == false && paused.isPaused == true)
    }

    @Test func invalidSchedulesHaveNoPreviewAndDoNotCrashTheAgenda() {
        for invalid in [reminder(day: 0), reminder(day: 29), reminder(weekday: 0),
                        reminder(weekday: 8), reminder(hour: 24), reminder(hour: -1)] {
            #expect(invalid.nextOccurrence(after: date(), calendar: calendar()) == nil)
            #expect(ReminderAgenda.items([invalid], asOf: date(), calendar: calendar()).first?.group == .needsAttention)
        }
        var invalidMinute = reminder()
        invalidMinute.minute = 60
        #expect(invalidMinute.nextOccurrence(after: date(), calendar: calendar()) == nil)
    }

    @Test func daylightSavingUsesCalendarOccurrencesRatherThanFixedDayDurations() throws {
        let ny = calendar("America/New_York")
        let sunday = reminder(frequency: .weekly, weekday: 1)
        let before = date(2026, 3, 7, 10, calendar: ny)
        let occurrence = try #require(sunday.nextOccurrence(after: before, calendar: ny))
        #expect(occurrence == date(2026, 3, 8, 9, calendar: ny))
        #expect(occurrence.timeIntervalSince(before) == 22 * 3600)
        #expect(sunday.nextOccurrence(after: date(2026, 10, 31, 10, calendar: ny), calendar: ny)
            == date(2026, 11, 1, 9, calendar: ny))
    }

    @Test func searchMatchesNameIgnoringCaseAccentsAndExtraWhitespaceAndCombinesWithFrequency() {
        let monthly = reminder("Café   mobile bill")
        let weekly = reminder("CAFE mobile weekly", frequency: .weekly)
        let other = reminder("Rent")
        let input = [other, monthly, weekly]
        #expect(ReminderAgenda.items(input, asOf: date(), calendar: calendar(), search: " cafe  MOBILE ").count == 2)
        #expect(ReminderAgenda.items(input, asOf: date(), calendar: calendar(), search: "cafe mobile",
            frequency: .monthly).map(\.id) == [monthly.id])
        #expect(ReminderAgenda.items(input, asOf: date(), calendar: calendar(), search: "   ").count == 3)
        #expect(ReminderAgenda.items(input, asOf: date(), calendar: calendar(), search: "no such name").isEmpty)
        #expect(monthly.title == "Café   mobile bill" && !weekly.isPaused)
    }

    @Test func nextSevenDaysIncludesTodayThroughSixDaysLaterAndUsesCalendarBoundariesAcrossDST() {
        for zone in ["Asia/Colombo", "America/New_York"] {
            let cal = calendar(zone)
            let reference = date(2026, 10, 31, 12, calendar: cal)
            var today = reminder("Today", frequency: .once, hour: 13)
            today.date = reference
            var lastDay = reminder("Last day", frequency: .once, hour: 23)
            lastDay.date = date(2026, 11, 6, 8, calendar: cal)
            var boundary = reminder("Boundary", frequency: .once, hour: 0)
            boundary.date = date(2026, 11, 7, 0, calendar: cal)
            var paused = today
            paused = LedgerReminder(id: UUID(), title: "Paused", amount: nil, frequency: .once,
                dayOfMonth: 1, weekday: 1, date: reference, hour: 14, minute: 0, isPaused: true)
            let result = ReminderAgenda.items([boundary, paused, lastDay, today], asOf: reference,
                calendar: cal, filter: .nextSevenDays)
            #expect(result.map(\.id) == [today.id, lastDay.id])
            #expect(ReminderAgenda.items([today], asOf: reference, calendar: cal,
                filter: .nextSevenDays, frequency: .weekly).isEmpty)
        }
    }

    @Test func pausedAndPastFiltersStayDisjointWhenAOneTimeDateExpires() {
        let active = reminder("Active")
        let paused = reminder("Paused", paused: true)
        var past = reminder("Past", frequency: .once)
        past.date = date(2026, 10, 19)
        var pausedPast = past
        pausedPast.isPaused = true
        let rows = [active, paused, past]
        #expect(ReminderAgenda.items(rows, asOf: date(), calendar: calendar(), filter: .paused).map(\.id) == [paused.id])
        #expect(ReminderAgenda.items(rows, asOf: date(), calendar: calendar(), filter: .needsAttention).map(\.id) == [past.id])
        #expect(ReminderAgenda.items([pausedPast], asOf: date(), calendar: calendar(), filter: .needsAttention).isEmpty)
        #expect(ReminderAgenda.items(rows, asOf: date(), calendar: calendar(), filter: .paused, frequency: .once).isEmpty)
    }

    @Test func deletingAFilteredResultPreservesHiddenAndOtherFrequencyReminders() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let hidden = reminder("Mobile plan", frequency: .weekly)
        let selected = reminder("Mobile plan", frequency: .monthly)
        let unrelated = reminder("Rent")
        for row in [hidden, selected, unrelated] { try repository.saveReminder(row) }
        let visible = ReminderAgenda.items(try repository.fetchReminders(), asOf: date(), calendar: calendar(),
            search: "mobile", frequency: .monthly)
        #expect(visible.map(\.id) == [selected.id])
        for row in visible { try repository.deleteReminder(id: row.id) }
        #expect(Set(try repository.fetchReminders().map(\.id)) == Set([hidden.id, unrelated.id]))
    }

    @Test func deletingFromAGroupedAgendaUsesDisplayedIdentityWithoutChangingOtherReminders() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let soon = reminder("Z early")
        let later = reminder("A later", hour: 12)
        let paused = reminder("A paused", paused: true)
        for row in [paused, later, soon] { try repository.saveReminder(row) }
        let saved = try repository.fetchReminders()
        let upcoming = ReminderAgenda.items(saved, asOf: date(), calendar: calendar()).filter { $0.group == .upcoming }
        let selected = try #require(upcoming.first)
        #expect(selected.id == soon.id)
        try repository.deleteReminder(id: selected.id)
        let remaining = try repository.fetchReminders()
        #expect(Set(remaining.map(\.id)) == Set([later.id, paused.id]))
        #expect(remaining.first { $0.id == paused.id }?.isPaused == true)
    }
}
