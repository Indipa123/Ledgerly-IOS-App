//
//  Ledgerly_IOS_AppApp.swift
//  Ledgerly IOS App
//
//  Created by Indipa Ayomal on 2026-09-30.
//

import SwiftUI
import FirebaseCore
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
        notifications.setNotificationCategories([
            UNNotificationCategory(identifier: "LEDGERLY_REMINDER", actions: [record, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: "LEDGERLY_PLACE", actions: [record], intentIdentifiers: []),
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
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == "LEDGERLY_SNOOZE" {
            guard let content = response.notification.request.content.mutableCopy() as? UNMutableNotificationContent else { return }
            let request = UNNotificationRequest(identifier: response.notification.request.identifier + ".snooze",
                                                content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 86_400, repeats: false))
            try? await center.add(request)
            return
        }
        let supplied = response.notification.request.content.userInfo["destination"] as? String
        let destination = response.actionIdentifier == "LEDGERLY_RECORD" ?
            (supplied?.hasPrefix("placeExpense:") == true ? supplied! : "addExpense") :
            (supplied ?? "reminders")
        await MainActor.run {
            UserDefaults.standard.set(destination, forKey: "ledgerly.pendingNotificationDestination")
            NotificationCenter.default.post(name: .ledgerlyNotificationDestination, object: nil)
        }
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
    }
}
