//
//  Ledgerly_IOS_AppApp.swift
//  Ledgerly IOS App
//
//  Created by Indipa Ayomal on 2026-09-30.
//

import SwiftUI
import FirebaseCore
import FirebaseAuth
import GoogleSignIn
import UIKit
import UserNotifications

final class LedgerlyAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let notifications = UNUserNotificationCenter.current()
        notifications.delegate = self
        let record = UNNotificationAction(identifier: "LEDGERLY_RECORD", title: "Record expense")
        let snooze = UNNotificationAction(identifier: "LEDGERLY_SNOOZE", title: "Snooze 1 day")
        let dismissPlace = UNNotificationAction(identifier: "LEDGERLY_DISMISS_PLACE", title: "Dismiss")
        notifications.setNotificationCategories([
            UNNotificationCategory(identifier: "LEDGERLY_REMINDER", actions: [record, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: "LEDGERLY_PLACE", actions: [record], intentIdentifiers: []),
            UNNotificationCategory(identifier: "LEDGERLY_PLACE_EXPENSE", actions: [record, dismissPlace],
                intentIdentifiers: [], options: .customDismissAction),
            UNNotificationCategory(identifier: "LEDGERLY_PLACE_DEPARTURE", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "LEDGERLY_BUDGET", actions: [], intentIdentifiers: [])
        ])
        if Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil {
            FirebaseApp.configure()
        }
        Task { @MainActor in PlaceArrivalMonitor.shared.bootstrapAfterLaunch() }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.content.categoryIdentifier == "LEDGERLY_REMINDER" {
            let valid = await MainActor.run { self.currentReminder(for: notification.request) != nil }
            if !valid { return [] }
        }
        if notification.request.content.categoryIdentifier == "LEDGERLY_REMINDER",
           BudgetAlertPreferences(defaults: .standard).silencesReminder(at: .now) {
            return [.banner]
        }
        return notification.request.content.sound == nil ? [.banner] : [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        // A delivery test opens the app without navigating to payment reminders
        // or creating an expense intent.
        if response.notification.request.identifier == "ledgerly.notification.deliveryTest" { return }
        if response.notification.request.content.categoryIdentifier == "LEDGERLY_REMINDER" {
            await handleReminderResponse(response, center: center)
            return
        }
        if response.actionIdentifier == UNNotificationDismissActionIdentifier ||
            response.actionIdentifier == "LEDGERLY_DISMISS_PLACE" {
            let content = response.notification.request.content
            guard content.categoryIdentifier == "LEDGERLY_PLACE_EXPENSE",
                  let owner = content.userInfo["arrivalOwner"] as? String,
                  let rawID = content.userInfo["arrivalVisitID"] as? String,
                  let visitID = UUID(uuidString: rawID) else { return }
            await MainActor.run {
                PlaceArrivalMonitor.shared.dismissArrivalNotification(owner: owner, visitID: visitID)
            }
            return
        }
        if response.actionIdentifier == "LEDGERLY_SNOOZE" { return }
        let supplied = response.notification.request.content.userInfo["destination"] as? String
        let destination = response.actionIdentifier == "LEDGERLY_RECORD" ?
            (supplied?.hasPrefix("placeExpense:") == true ? supplied! : "addExpense") :
            (supplied ?? "reminders")
        await MainActor.run {
            UserDefaults.standard.set(destination, forKey: "ledgerly.pendingNotificationDestination")
            NotificationCenter.default.post(name: .ledgerlyNotificationDestination, object: nil)
        }
    }

    @MainActor
    private func currentReminder(for request: UNNotificationRequest) -> (owner: String, reminder: LedgerReminder)? {
        let uid = FirebaseApp.app() == nil ? nil : Auth.auth().currentUser?.uid
        let owner = uid ?? "guest"
        guard request.content.categoryIdentifier == "LEDGERLY_REMINDER",
              ReminderNotificationIdentity.belongsToOwner(request.identifier, owner: owner),
              !AccountDeletionJournal.shared.blocks(owner: uid),
              let reminders = try? CoreDataLedgerRepository(accountID: uid).fetchReminders(),
              let reminder = ReminderNotificationIdentity.activeReminder(request.identifier,
                  owner: owner, reminders: reminders) else { return nil }
        return (owner, reminder)
    }

    @MainActor
    private func handleReminderResponse(_ response: UNNotificationResponse, center: UNUserNotificationCenter) async {
        let original = response.notification.request
        guard let initial = currentReminder(for: original) else { return }
        if response.actionIdentifier == "LEDGERLY_SNOOZE" {
            guard let identifier = ReminderNotificationIdentity.snoozeIdentifier(original.identifier, owner: initial.owner) else { return }
            let pending = await center.pendingNotificationRequests()
            guard let current = currentReminder(for: original), current.owner == initial.owner else { return }
            // Coalesce both canonical and legacy snoozes; retain the regular repeating request.
            let oldSnoozes = ReminderNotificationIdentity.snoozeIdentifiers(in: pending.map(\.identifier),
                reminderID: current.reminder.id, owner: current.owner)
            center.removePendingNotificationRequests(withIdentifiers: oldSnoozes)
            let content = UNMutableNotificationContent()
            content.title = current.reminder.title
            content.body = current.reminder.amount.map { "\(LKR.string($0)) due" } ?? "Time to check this payment."
            content.categoryIdentifier = "LEDGERLY_REMINDER"
            content.threadIdentifier = "ledgerly.reminders"
            content.userInfo = ["destination": "reminders"]
            let date = Date.now.addingTimeInterval(86_400)
            content.sound = BudgetAlertPreferences(defaults: .standard).silencesReminder(at: date) ? nil : .default
            var parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            parts.timeZone = .current
            let request = UNNotificationRequest(identifier: identifier, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            try? await center.add(request)
            if currentReminder(for: original)?.owner != current.owner {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
            }
            return
        }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier ||
              response.actionIdentifier == "LEDGERLY_RECORD" else { return }
        UserDefaults.standard.set(response.actionIdentifier == "LEDGERLY_RECORD" ? "addExpense" : "reminders",
            forKey: "ledgerly.pendingNotificationDestination")
        NotificationCenter.default.post(name: .ledgerlyNotificationDestination, object: nil)
    }
}

extension Notification.Name {
    static let ledgerlyNotificationDestination = Notification.Name("ledgerlyNotificationDestination")
}

@main
struct Ledgerly_IOS_AppApp: App {
    @UIApplicationDelegateAdaptor(LedgerlyAppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance = 0

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
        .commands { LedgerKeyboardCommands() }
    }
}
