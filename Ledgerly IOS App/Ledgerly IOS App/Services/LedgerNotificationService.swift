import Combine
import Foundation
import UserNotifications

@MainActor
final class LedgerNotificationService: ObservableObject {
    @Published private(set) var budgetPreferences: BudgetAlertPreferences
    @Published private(set) var isUpdatingPreferences = false
    @Published private(set) var permissionText = "Checking permission…"
    @Published private(set) var deliverySettings: [(title: String, value: String)] = []
    @Published private(set) var isSendingTest = false
    @Published private(set) var testNotificationMessage: String?
    @Published var error: String?

    private let center = UNUserNotificationCenter.current()
    private let defaults: UserDefaults
    private var activeOwner = "guest"
    private var accountGeneration = 0
    private var preferenceVersion = 0
    private let testRequestID = "ledgerly.notification.deliveryTest"

    var budgetAlertsEnabled: Bool { budgetPreferences.monthlyEnabled }
    var categoryBudgetAlertsEnabled: Bool { budgetPreferences.categoryEnabled }
    var budgetQuietHours: BudgetQuietHours { budgetPreferences.quietHours }
    var quietReminderSounds: Bool { budgetPreferences.quietReminderSounds }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        budgetPreferences = BudgetAlertPreferences(defaults: defaults)
        budgetPreferences.save(to: defaults)
        Task { await refreshPermission() }
    }

    func refreshPermission() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: permissionText = "Allowed"
        case .denied: permissionText = "Denied in device Settings"
        case .notDetermined: permissionText = "Not requested"
        @unknown default: permissionText = "Unavailable"
        }
        func label(_ setting: UNNotificationSetting) -> String {
            switch setting {
            case .enabled: "On"
            case .disabled: "Off"
            case .notSupported: "Not supported"
            @unknown default: "Unavailable"
            }
        }
        deliverySettings = [
            ("Banners and alerts", label(settings.alertSetting)),
            ("Lock Screen", label(settings.lockScreenSetting)),
            ("Notification Centre", label(settings.notificationCenterSetting)),
            ("Sounds", label(settings.soundSetting)),
            ("Scheduled Summary", label(settings.scheduledDeliverySetting))
        ]
    }

    func sendTestNotification() async {
        guard !isSendingTest else { return }
        isSendingTest = true
        testNotificationMessage = nil
        error = nil
        let generation = accountGeneration
        defer { isSendingTest = false }
        guard await requestPermission() else {
            if generation == accountGeneration {
                error = "Allow notifications for Ledgerly in device Settings, then try again."
            }
            return
        }
        guard generation == accountGeneration else { return }
        let content = UNMutableNotificationContent()
        content.title = "Ledgerly notification test"
        content.body = "Notifications reached this device. Arrival alerts also need Always location and an enabled saved place."
        content.sound = .default
        content.threadIdentifier = "ledgerly.notificationTests"
        // Contains no ledger amounts, account identifiers or location data.
        let request = UNNotificationRequest(identifier: testRequestID, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
        do {
            center.removePendingNotificationRequests(withIdentifiers: [testRequestID])
            center.removeDeliveredNotifications(withIdentifiers: [testRequestID])
            try await center.add(request)
            guard generation == accountGeneration else {
                center.removePendingNotificationRequests(withIdentifiers: [testRequestID])
                center.removeDeliveredNotifications(withIdentifiers: [testRequestID])
                return
            }
            testNotificationMessage = "Test scheduled for about 5 seconds from now. You can leave Ledgerly to check delivery. Scheduling does not confirm that a banner appeared."
        } catch {
            if generation == accountGeneration { self.error = "Could not schedule the test: \(error.localizedDescription)" }
        }
    }

    func requestPermission() async -> Bool {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            } catch {
                self.error = error.localizedDescription
            }
        }
        await refreshPermission()
        return permissionText == "Allowed"
    }

    func setBudgetAlertsEnabled(_ enabled: Bool) async {
        await setAlertsEnabled(enabled, type: .monthly)
    }

    func setCategoryBudgetAlertsEnabled(_ enabled: Bool) async {
        await setAlertsEnabled(enabled, type: .category)
    }

    func setAccount(_ uid: String?) {
        let next = uid ?? "guest"
        if next != activeOwner {
            activeOwner = next
            accountGeneration += 1
            testNotificationMessage = nil
            center.removePendingNotificationRequests(withIdentifiers: [testRequestID])
            center.removeDeliveredNotifications(withIdentifiers: [testRequestID])
        }
        let generation = accountGeneration
        Task {
            let pending = await center.pendingNotificationRequests()
            let delivered = await center.deliveredNotifications()
            guard activeOwner == next, generation == accountGeneration else { return }
            let prefixes = [BudgetAlertType.monthly.requestPrefix, BudgetAlertType.category.requestPrefix]
            func belongsToAnotherAccount(_ request: UNNotificationRequest) -> Bool {
                if request.identifier.hasPrefix("reminder.") {
                    // Also retire old nested snoozes whose reminder may already
                    // have been deleted before this version was installed.
                    return !ReminderNotificationIdentity.belongsToOwner(request.identifier, owner: next) ||
                        request.identifier.hasSuffix(".snooze.snooze")
                }
                guard prefixes.contains(where: { request.identifier.hasPrefix($0) }) else { return false }
                if let owner = request.content.userInfo["budgetOwner"] as? String { return owner != next }
                return !prefixes.contains { request.identifier.hasPrefix($0 + next + ".") }
            }
            center.removePendingNotificationRequests(withIdentifiers: pending.filter(belongsToAnotherAccount).map(\.identifier))
            center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request).filter(belongsToAnotherAccount).map(\.identifier))
        }
    }

    @discardableResult
    func setBudgetQuietHours(_ hours: BudgetQuietHours, quietReminderSounds: Bool? = nil) async -> Bool {
        guard !isUpdatingPreferences else { return false }
        guard !hours.enabled || hours.isValid else {
            error = "Choose different start and end times."
            return false
        }
        isUpdatingPreferences = true
        error = nil
        defer { isUpdatingPreferences = false }
        budgetPreferences.quietHours = hours.isValid ? hours : BudgetQuietHours()
        if let quietReminderSounds { budgetPreferences.quietReminderSounds = quietReminderSounds }
        budgetPreferences.save(to: defaults)
        preferenceVersion += 1
        let generation = accountGeneration
        let owner = activeOwner
        let requests = await center.pendingNotificationRequests()
        for request in requests {
            guard generation == accountGeneration else { return true }
            if request.content.categoryIdentifier == "LEDGERLY_REMINDER",
               ReminderNotificationIdentity.belongsToOwner(request.identifier, owner: owner) {
                do { _ = try await scheduleReminderRequest(request, owner: owner, generation: generation) }
                catch { self.error = error.localizedDescription; return false }
                continue
            }
            if let recordedOwner = request.content.userInfo["budgetOwner"] as? String, recordedOwner != owner { continue }
            let type: BudgetAlertType
            if request.identifier.hasPrefix(BudgetAlertType.monthly.requestPrefix + owner + ".") { type = .monthly }
            else if request.identifier.hasPrefix(BudgetAlertType.category.requestPrefix + owner + ".") { type = .category }
            else { continue }
            guard await scheduleBudgetRequest(id: request.identifier, content: request.content,
                                              type: type, owner: owner, generation: generation) else {
                if error != nil { return false }
                continue
            }
        }
        return true
    }

    private func setAlertsEnabled(_ enabled: Bool, type: BudgetAlertType) async {
        guard !isUpdatingPreferences else { return }
        isUpdatingPreferences = true
        error = nil
        defer { isUpdatingPreferences = false }
        if enabled {
            let allowed = await requestPermission()
            guard allowed else {
                error = "Allow notifications in device Settings to receive budget alerts."
                return
            }
        }
        budgetPreferences.set(enabled, for: type)
        preferenceVersion += 1
        budgetPreferences.save(to: defaults)
        if !enabled {
            let requests = await center.pendingNotificationRequests()
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(type.requestPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    private func reminderID(_ id: UUID, owner: String?) -> String {
        "reminder.\(owner ?? "guest").\(id.uuidString)"
    }

    func cancel(_ reminder: LedgerReminder, owner: String?) {
        let id = reminderID(reminder.id, owner: owner)
        center.removePendingNotificationRequests(withIdentifiers: [id, id + ".snooze"])
        center.removeDeliveredNotifications(withIdentifiers: [id, id + ".snooze"])
        let account = owner ?? "guest"
        // Older versions appended another suffix each time. Remove those legacy
        // copies without racing a fresh base/canonical request scheduled after cancel.
        Task {
            let pending = await center.pendingNotificationRequests()
            let delivered = await center.deliveredNotifications()
            center.removePendingNotificationRequests(withIdentifiers: ReminderNotificationIdentity.snoozeIdentifiers(
                in: pending.map(\.identifier), reminderID: reminder.id, owner: account, legacyOnly: true))
            center.removeDeliveredNotifications(withIdentifiers: ReminderNotificationIdentity.snoozeIdentifiers(
                in: delivered.map { $0.request.identifier }, reminderID: reminder.id, owner: account, legacyOnly: true))
        }
    }

    func cancelAll(_ reminders: [LedgerReminder], owner: String?) {
        reminders.forEach { cancel($0, owner: owner) }
    }

    func schedule(_ reminder: LedgerReminder, owner: String?) async throws {
        guard activeOwner == (owner ?? "guest") else { return }
        let generation = accountGeneration
        cancel(reminder, owner: owner)
        guard !AccountDeletionJournal.shared.blocks(owner: owner) else { return }
        guard !reminder.isPaused else { return }
        // Past one-time schedules have no future trigger; do not submit them again on launch.
        guard reminder.nextOccurrence() != nil else { return }
        let settings = await center.notificationSettings()
        guard generation == accountGeneration, !AccountDeletionJournal.shared.blocks(owner: owner) else { return }
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.amount.map { "\(LKR.string($0)) due" } ?? "Time to check this payment."
        content.sound = .default
        content.categoryIdentifier = "LEDGERLY_REMINDER"
        content.threadIdentifier = "ledgerly.reminders"
        content.userInfo = ["destination": "reminders"]
        let trigger = UNCalendarNotificationTrigger(dateMatching: reminder.dateComponents,
                                                    repeats: reminder.frequency != .once)
        _ = try await scheduleReminderRequest(UNNotificationRequest(identifier: reminderID(reminder.id, owner: owner),
            content: content, trigger: trigger), owner: owner ?? "guest", generation: generation)
    }

    private func scheduleReminderRequest(_ request: UNNotificationRequest, owner: String,
                                         generation: Int) async throws -> Bool {
        var preservedTrigger = request.trigger
        // Re-adding an interval trigger would restart its delay. Preserve legacy
        // snoozes as an absolute calendar date before changing their sound.
        if let interval = request.trigger as? UNTimeIntervalNotificationTrigger,
           !interval.repeats, let date = interval.nextTriggerDate() {
            var parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            parts.timeZone = .current
            preservedTrigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        }
        while true {
            guard generation == accountGeneration, activeOwner == owner,
                  !AccountDeletionJournal.shared.blocks(owner: owner),
                  let content = request.content.mutableCopy() as? UNMutableNotificationContent else { return false }
            let version = preferenceVersion
            let silent: Bool
            if let trigger = preservedTrigger as? UNCalendarNotificationTrigger,
               !trigger.repeats, let delivery = trigger.nextTriggerDate() {
                silent = budgetPreferences.silencesReminder(at: delivery)
            } else if let trigger = preservedTrigger as? UNCalendarNotificationTrigger,
               let hour = trigger.dateComponents.hour, let minute = trigger.dateComponents.minute {
                // Repeating requests retain their selected local clock time, day and repeat rule.
                silent = budgetPreferences.silencesReminder(hour: hour, minute: minute)
            } else { return false }
            content.sound = silent ? nil : .default
            try await center.add(UNNotificationRequest(identifier: request.identifier,
                content: content, trigger: preservedTrigger))
            guard generation == accountGeneration, activeOwner == owner,
                  !AccountDeletionJournal.shared.blocks(owner: owner) else {
                center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                return false
            }
            if version == preferenceVersion { return true }
        }
    }

    func scheduleExisting(_ reminders: [LedgerReminder], owner: String?) async {
        for reminder in reminders {
            do { try await schedule(reminder, owner: owner) }
            catch { self.error = error.localizedDescription }
        }
    }

    func checkBudgetCrossing(previous: Decimal, current: Decimal, budget: Decimal, owner: String?) async {
        guard budgetAlertsEnabled, activeOwner == (owner ?? "guest") else { return }
        let generation = accountGeneration
        let decision = BudgetAlertDecision.crossing(from: previous, to: current, budget: budget)
        guard decision != .none else { return }
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            await refreshPermission()
            return
        }
        let month = Date.now.formatted(.dateTime.year().month(.twoDigits))
        let level = decision == .warning ? "warning" : "over"
        let key = "ledgerly.budgetAlert.\(owner ?? "guest").\(month).\(level)"
        guard generation == accountGeneration, budgetAlertsEnabled, !defaults.bool(forKey: key) else { return }
        let period = Date.now.formatted(.dateTime.month(.wide).year())
        let content = UNMutableNotificationContent()
        content.title = decision == .warning ? "Budget warning" : "Budget reached"
        if decision == .warning {
            content.body = "You've used at least 80% of your \(period) budget."
        } else {
            content.body = current == budget ? "You've reached your \(period) budget." :
                "You're \(LKR.string(current - budget)) over your \(period) budget."
        }
        content.sound = .default
        content.categoryIdentifier = "LEDGERLY_BUDGET"
        content.threadIdentifier = "ledgerly.budget"
        content.userInfo = ["destination": "budget", "budgetOwner": owner ?? "guest"]
        if await scheduleBudgetRequest(id: key, content: content, type: .monthly,
                                       owner: owner ?? "guest", generation: generation) {
            defaults.set(true, forKey: key)
        }
    }

    func checkCategoryBudgetCrossing(previous: Decimal, current: Decimal,
                                     limit: CategoryBudget, owner: String?) async {
        guard categoryBudgetAlertsEnabled, activeOwner == (owner ?? "guest") else { return }
        let generation = accountGeneration
        let decision = BudgetAlertDecision.crossing(from: previous, to: current, budget: limit.amount)
        guard decision != .none else { return }
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            await refreshPermission()
            return
        }
        let level = decision == .warning ? "warning" : "over"
        let key = "ledgerly.categoryBudgetAlert.\(owner ?? "guest").\(limit.id).\(level)"
        guard generation == accountGeneration, categoryBudgetAlertsEnabled, !defaults.bool(forKey: key) else { return }
        let period = Date.now.formatted(.dateTime.month(.wide).year())
        let content = UNMutableNotificationContent()
        content.title = decision == .warning ? "Category limit warning" : "Category limit reached"
        if decision == .warning {
            content.body = "You've used at least 80% of your \(limit.categoryName) limit for \(period)."
        } else {
            content.body = current == limit.amount ?
                "You've reached your \(limit.categoryName) limit for \(period)." :
                "You're \(LKR.string(current - limit.amount)) over your \(limit.categoryName) limit for \(period)."
        }
        content.sound = .default
        content.categoryIdentifier = "LEDGERLY_BUDGET"
        content.threadIdentifier = "ledgerly.budget"
        content.userInfo = ["destination": "budget", "budgetOwner": owner ?? "guest"]
        if await scheduleBudgetRequest(id: key, content: content, type: .category,
                                       owner: owner ?? "guest", generation: generation) {
            defaults.set(true, forKey: key)
        }
    }

    private func scheduleBudgetRequest(id: String, content: UNNotificationContent, type: BudgetAlertType,
                                       owner: String, generation: Int) async -> Bool {
        while true {
            guard owner == activeOwner, generation == accountGeneration, budgetPreferences.isEnabled(type),
                  !AccountDeletionJournal.shared.blocks(owner: owner) else {
                center.removePendingNotificationRequests(withIdentifiers: [id])
                center.removeDeliveredNotifications(withIdentifiers: [id])
                return false
            }
            let version = preferenceVersion
            let date = budgetQuietHours.deliveryDate(after: .now)
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let request = UNNotificationRequest(identifier: id, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            do { try await center.add(request) }
            catch { self.error = error.localizedDescription; return false }
            guard owner == activeOwner, generation == accountGeneration, budgetPreferences.isEnabled(type),
                  !AccountDeletionJournal.shared.blocks(owner: owner) else {
                center.removePendingNotificationRequests(withIdentifiers: [id])
                center.removeDeliveredNotifications(withIdentifiers: [id])
                return false
            }
            if version == preferenceVersion { return true }
        }
    }
}
