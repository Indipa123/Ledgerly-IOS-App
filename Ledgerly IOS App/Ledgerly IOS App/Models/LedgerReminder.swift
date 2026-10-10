import Foundation

enum ReminderFrequency: Int16, CaseIterable, Identifiable {
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

struct LedgerReminder: Identifiable {
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

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (amount == nil || amount! >= 0) &&
        (1...28).contains(dayOfMonth) && (1...7).contains(weekday) &&
        (0...23).contains(hour) && (0...59).contains(minute) &&
        (frequency != .once || (Calendar.current.date(from: dateComponents) ?? .distantPast) > .now)
    }

    var dateComponents: DateComponents {
        var result = DateComponents()
        switch frequency {
        case .monthly: result.day = dayOfMonth
        case .weekly: result.weekday = weekday
        case .once:
            let dateParts = Calendar.current.dateComponents([.year, .month, .day], from: date)
            result.year = dateParts.year
            result.month = dateParts.month
            result.day = dateParts.day
        }
        result.hour = hour
        result.minute = minute
        return result
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
