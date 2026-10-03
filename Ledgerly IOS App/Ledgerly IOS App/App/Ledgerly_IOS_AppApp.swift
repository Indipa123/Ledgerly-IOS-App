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

final class LedgerlyAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil {
            FirebaseApp.configure()
        }
        return true
    }
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
