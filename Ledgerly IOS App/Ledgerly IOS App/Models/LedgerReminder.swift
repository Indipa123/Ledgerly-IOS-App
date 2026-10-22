import Foundation

enum ReminderFrequency: Int16, CaseIterable, Identifiable, Codable {
    case monthly, weekly, once

    var id: Self { self }
    var title: String {
        switch self {
        case .monthly: "Monthly"
        case .weekly: "Weekly"
        case .once: "One time"
        }
    }
}

struct LedgerReminder: Identifiable, Codable {
    let id: UUID
    var title: String
    var amount: Decimal?
    var frequency: ReminderFrequency
    var dayOfMonth: Int
    var weekday: Int
    var date: Date
    var hour: Int
    var minute: Int
    var isPaused: Bool

    var isValid: Bool { hasValidFields && (frequency != .once || nextOccurrence() != nil) }

    var hasValidFields: Bool {
        date.timeIntervalSince1970.isFinite && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (amount == nil || amount! >= 0) &&
        (1...28).contains(dayOfMonth) && (1...7).contains(weekday) &&
        (0...23).contains(hour) && (0...59).contains(minute)
    }

    var dateComponents: DateComponents { dateComponents(calendar: .current) }

    func dateComponents(calendar: Calendar) -> DateComponents {
        var result = DateComponents()
        switch frequency {
        case .monthly: result.day = dayOfMonth
        case .weekly: result.weekday = weekday
        case .once:
            let dateParts = calendar.dateComponents([.year, .month, .day], from: date)
            result.year = dateParts.year
            result.month = dateParts.month
            result.day = dateParts.day
        }
        result.hour = hour
        result.minute = minute
        return result
    }

    /// Schedule preview in the supplied local calendar. iOS controls actual delivery.
    /// Paused state is handled by the caller, so this also describes a saved paused schedule.
    func nextOccurrence(after reference: Date = .now, calendar: Calendar = .current) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute),
              (1...28).contains(dayOfMonth), (1...7).contains(weekday) else { return nil }
        if frequency == .once {
            guard let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0,
                of: date, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
                  calendar.isDate(candidate, inSameDayAs: date), candidate > reference else { return nil }
            return candidate
        }
        return calendar.nextDate(after: reference, matching: dateComponents(calendar: calendar),
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }
}

enum ReminderAgendaGroup: CaseIterable, Hashable {
    case upcoming, paused, needsAttention

    var title: String {
        switch self {
        case .upcoming: "Upcoming payments"
        case .paused: "Paused"
        case .needsAttention: "Past or unscheduled"
        }
    }
}

struct ReminderAgendaItem: Identifiable {
    var id: UUID { reminder.id }
    let reminder: LedgerReminder
    let nextDate: Date?
    let group: ReminderAgendaGroup
}

enum ReminderAgendaFilter: String, CaseIterable, Identifiable {
    case all, nextSevenDays, paused, needsAttention
    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All reminders"
        case .nextSevenDays: "Next 7 days"
        case .paused: "Paused"
        case .needsAttention: "Past or unscheduled"
        }
    }
}

enum ReminderAgenda {
    static func items(_ reminders: [LedgerReminder], asOf reference: Date = .now,
                      calendar: Calendar = .current, search: String = "",
                      filter: ReminderAgendaFilter = .all,
                      frequency: ReminderFrequency? = nil) -> [ReminderAgendaItem] {
        let query = normalized(search)
        // Seven calendar dates including today; do not treat a DST week as 168 hours.
        let end = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: reference))
        return reminders.map { reminder in
            let next = reminder.nextOccurrence(after: reference, calendar: calendar)
            return ReminderAgendaItem(reminder: reminder, nextDate: next,
                group: reminder.isPaused ? .paused : next == nil ? .needsAttention : .upcoming)
        }.filter { item in
            guard (frequency == nil || item.reminder.frequency == frequency),
                  query.isEmpty || normalized(item.reminder.title).contains(query) else { return false }
            switch filter {
            case .all: return true
            case .nextSevenDays:
                guard item.group == .upcoming, let next = item.nextDate, let end else { return false }
                return next > reference && next < end
            case .paused: return item.group == .paused
            case .needsAttention: return item.group == .needsAttention
            }
        }.sorted { left, right in
            if left.group != right.group {
                return rank(left.group) < rank(right.group)
            }
            if left.group == .upcoming, left.nextDate != right.nextDate {
                return (left.nextDate ?? .distantFuture) < (right.nextDate ?? .distantFuture)
            }
            let order = left.reminder.title.localizedCaseInsensitiveCompare(right.reminder.title)
            return order == .orderedSame ? left.id.uuidString < right.id.uuidString : order == .orderedAscending
        }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func rank(_ group: ReminderAgendaGroup) -> Int {
        switch group { case .upcoming: 0; case .paused: 1; case .needsAttention: 2 }
    }
}

enum BudgetAlertDecision: Equatable {
    case none, warning, overBudget

    static func crossing(from previous: Decimal, to current: Decimal, budget: Decimal) -> Self {
        guard budget > 0 else { return .none }
        if previous < budget && current >= budget { return .overBudget }
        if previous < budget * Decimal(string: "0.8")! &&
            current >= budget * Decimal(string: "0.8")! { return .warning }
        return .none
    }
}
