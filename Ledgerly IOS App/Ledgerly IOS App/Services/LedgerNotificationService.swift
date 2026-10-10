import Combine
import Foundation
import UserNotifications

@MainActor
final class LedgerNotificationService: ObservableObject {
    @Published private(set) var budgetAlertsEnabled: Bool
    @Published private(set) var permissionText = "Checking permission…"
    @Published var error: String?

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private static let budgetPreferenceKey = "ledgerly.notifications.budgetEnabled"

    init() {
        budgetAlertsEnabled = UserDefaults.standard.bool(forKey: Self.budgetPreferenceKey)
        Task { await refreshPermission() }
    }

    func refreshPermission() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: permissionText = "Allowed"
        case .denied: permissionText = "Denied in iPhone Settings"
        case .notDetermined: permissionText = "Not requested"
        @unknown default: permissionText = "Unavailable"
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
        if enabled {
            let allowed = await requestPermission()
            guard allowed else {
                error = "Allow notifications in iPhone Settings to receive budget alerts."
                return
            }
        }
        budgetAlertsEnabled = enabled
        defaults.set(enabled, forKey: Self.budgetPreferenceKey)
    }

    private func reminderID(_ id: UUID, owner: String?) -> String {
        "reminder.\(owner ?? "guest").\(id.uuidString)"
    }

    func cancel(_ reminder: LedgerReminder, owner: String?) {
        let id = reminderID(reminder.id, owner: owner)
        center.removePendingNotificationRequests(withIdentifiers: [id, id + ".snooze"])
        center.removeDeliveredNotifications(withIdentifiers: [id, id + ".snooze"])
    }

    func cancelAll(_ reminders: [LedgerReminder], owner: String?) {
        reminders.forEach { cancel($0, owner: owner) }
    }

    func schedule(_ reminder: LedgerReminder, owner: String?) async throws {
        cancel(reminder, owner: owner)
        guard !reminder.isPaused else { return }
        let settings = await center.notificationSettings()
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
        try await center.add(UNNotificationRequest(identifier: reminderID(reminder.id, owner: owner),
                                                   content: content, trigger: trigger))
    }

    func scheduleExisting(_ reminders: [LedgerReminder], owner: String?) async {
        for reminder in reminders {
            do { try await schedule(reminder, owner: owner) }
            catch { self.error = error.localizedDescription }
        }
    }

    func checkBudgetCrossing(previous: Decimal, current: Decimal, budget: Decimal, owner: String?) async {
        guard budgetAlertsEnabled else { return }
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
        guard !defaults.bool(forKey: key) else { return }
        let content = UNMutableNotificationContent()
        content.title = decision == .warning ? "Budget warning" : "Budget reached"
        if decision == .warning {
            content.body = "You've used at least 80% of this month's budget."
        } else {
            content.body = current == budget ? "You've reached this month's budget." :
                "You're \(LKR.string(current - budget)) over this month's budget."
        }
        content.sound = .default
        content.categoryIdentifier = "LEDGERLY_BUDGET"
        content.threadIdentifier = "ledgerly.budget"
        content.userInfo = ["destination": "budget"]
        let request = UNNotificationRequest(identifier: key, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        do {
            try await center.add(request)
            defaults.set(true, forKey: key)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
