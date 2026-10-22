import Foundation

enum BudgetAlertType {
    case monthly, category

    var requestPrefix: String {
        switch self {
        case .monthly: "ledgerly.budgetAlert."
        case .category: "ledgerly.categoryBudgetAlert."
        }
    }
}

struct BudgetQuietHours: Codable, Equatable {
    var enabled = false
    var startMinute = 22 * 60
    var endMinute = 8 * 60

    var isValid: Bool {
        (0..<1_440).contains(startMinute) && (0..<1_440).contains(endMinute) && startMinute != endMinute
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return contains(minuteOfDay: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    func contains(minuteOfDay minute: Int) -> Bool {
        guard enabled, isValid, (0..<1_440).contains(minute) else { return false }
        return startMinute < endMinute
            ? minute >= startMinute && minute < endMinute
            : minute >= startMinute || minute < endMinute
    }

    func deliveryDate(after now: Date, calendar: Calendar = .current) -> Date {
        let earliest = now.addingTimeInterval(1)
        guard contains(earliest, calendar: calendar) else { return earliest }
        let end = DateComponents(hour: endMinute / 60, minute: endMinute % 60, second: 0)
        // Use the final occurrence at a repeated clock time, and the next valid time
        // if the requested end falls inside a daylight-saving clock jump.
        return calendar.nextDate(after: earliest, matching: end, matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .last) ?? earliest.addingTimeInterval(86_400)
    }
}

struct BudgetAlertPreferences: Equatable {
    private static let monthlyKey = "ledgerly.notifications.budgetEnabled"
    private static let categoryKey = "ledgerly.notifications.categoryBudgetEnabled"
    private static let quietKey = "ledgerly.notifications.budgetQuietHours"
    private static let reminderSoundKey = "ledgerly.notifications.quietReminderSounds"
    var monthlyEnabled: Bool
    var categoryEnabled: Bool
    var quietHours = BudgetQuietHours()
    var quietReminderSounds = false

    init(defaults: UserDefaults) {
        monthlyEnabled = defaults.bool(forKey: Self.monthlyKey)
        // Previously one switch controlled both types. Preserve that choice on upgrade.
        categoryEnabled = defaults.object(forKey: Self.categoryKey) as? Bool ?? monthlyEnabled
        quietReminderSounds = defaults.bool(forKey: Self.reminderSoundKey)
        if let data = defaults.data(forKey: Self.quietKey),
           let hours = try? JSONDecoder().decode(BudgetQuietHours.self, from: data), hours.isValid {
            quietHours = hours
        }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(monthlyEnabled, forKey: Self.monthlyKey)
        defaults.set(categoryEnabled, forKey: Self.categoryKey)
        defaults.set(quietReminderSounds, forKey: Self.reminderSoundKey)
        if let data = try? JSONEncoder().encode(quietHours) { defaults.set(data, forKey: Self.quietKey) }
    }

    func isEnabled(_ type: BudgetAlertType) -> Bool {
        switch type {
        case .monthly: monthlyEnabled
        case .category: categoryEnabled
        }
    }

    mutating func set(_ enabled: Bool, for type: BudgetAlertType) {
        switch type {
        case .monthly: monthlyEnabled = enabled
        case .category: categoryEnabled = enabled
        }
    }

    func silencesReminder(hour: Int, minute: Int) -> Bool {
        quietReminderSounds && (0...23).contains(hour) && (0...59).contains(minute) &&
            quietHours.contains(minuteOfDay: hour * 60 + minute)
    }

    func silencesReminder(at date: Date, calendar: Calendar = .current) -> Bool {
        quietReminderSounds && quietHours.contains(date, calendar: calendar)
    }
}

nonisolated enum ReminderNotificationIdentity {
    static func belongsToOwner(_ identifier: String, owner: String) -> Bool {
        reminderID(identifier, owner: owner) != nil
    }

    static func reminderID(_ identifier: String, owner: String) -> UUID? {
        let prefix = "reminder.\(owner)."
        guard identifier.hasPrefix(prefix) else { return nil }
        let parts = identifier.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard let first = parts.first, let id = UUID(uuidString: String(first)),
              parts.dropFirst().allSatisfy({ $0 == "snooze" }) else { return nil }
        return id
    }

    static func snoozeIdentifier(_ identifier: String, owner: String) -> String? {
        reminderID(identifier, owner: owner).map { "reminder.\(owner).\($0.uuidString).snooze" }
    }

    static func matches(_ identifier: String, reminderID id: UUID, owner: String) -> Bool {
        reminderID(identifier, owner: owner) == id
    }

    static func snoozeIdentifiers(in identifiers: [String], reminderID id: UUID,
                                  owner: String, legacyOnly: Bool = false) -> [String] {
        identifiers.filter {
            $0.hasSuffix(legacyOnly ? ".snooze.snooze" : ".snooze") &&
                matches($0, reminderID: id, owner: owner)
        }
    }

    static func activeReminder(_ identifier: String, owner: String,
                               reminders: [LedgerReminder]) -> LedgerReminder? {
        guard let id = reminderID(identifier, owner: owner) else { return nil }
        return reminders.first { $0.id == id && !$0.isPaused }
    }
}
