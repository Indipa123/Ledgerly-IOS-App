import SwiftUI

struct AppearanceSettingsScreen: View {
    @AppStorage("appearance") private var appearance = 0

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearance) {
                    Label("System", systemImage: "iphone").tag(0)
                    Label("Light", systemImage: "sun.max").tag(1)
                    Label("Dark", systemImage: "moon").tag(2)
                }
                .pickerStyle(.inline)
            } footer: {
                Text("System follows this device's appearance setting.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NotificationSettingsScreen: View {
    @ObservedObject var notifications: LedgerNotificationService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Toggle("Monthly budget alerts", isOn: Binding(
                    get: { notifications.budgetAlertsEnabled },
                    set: { enabled in Task { await notifications.setBudgetAlertsEnabled(enabled) } }
                ))
                Toggle("Category limit alerts", isOn: Binding(
                    get: { notifications.categoryBudgetAlertsEnabled },
                    set: { enabled in Task { await notifications.setCategoryBudgetAlertsEnabled(enabled) } }
                ))
                if notifications.isUpdatingPreferences { ProgressView("Updating preferences…") }
            } header: {
                Text("Budget alerts")
            } footer: {
                Text("Get a warning when spending reaches 80% or 100% of a budget.")
            }
            .disabled(notifications.isUpdatingPreferences)
            Section {
                NavigationLink { BudgetQuietHoursScreen(notifications: notifications) } label: {
                    SettingsMenuRow(title: "Budget & reminder quiet hours",
                                    subtitle: notifications.budgetQuietHours.enabled
                                        ? (notifications.quietReminderSounds ? "Budget alerts held · reminder sounds silenced" : "Budget alerts held") : "Off",
                                    symbol: "moon.fill")
                }
                .disabled(notifications.isUpdatingPreferences)
            }
            Section("Device access") {
                LabeledContent("Notifications", value: notifications.permissionText)
                ForEach(notifications.deliverySettings, id: \.title) { setting in
                    LabeledContent(setting.title, value: setting.value)
                }
                Button("Open device Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            Section {
                Button {
                    Task { await notifications.sendTestNotification() }
                } label: {
                    HStack {
                        Label("Send test notification", systemImage: "bell.badge")
                        if notifications.isSendingTest { Spacer(); ProgressView() }
                    }
                }
                .disabled(notifications.isSendingTest)
                if let message = notifications.testNotificationMessage {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                }
            } header: {
                Text("Test delivery")
            } footer: {
                Text("Check that notifications reach this device. No financial or location details are included.")
            }
            Section("Other notifications") {
                Text("Manage payment schedules in Payment reminders and place alerts in Places.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await notifications.refreshPermission() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await notifications.refreshPermission() } }
        }
        .alert("Notification preferences", isPresented: Binding(
            get: { notifications.error != nil }, set: { if !$0 { notifications.error = nil } }
        )) {
            Button("OK") { notifications.error = nil }
        } message: {
            Text(notifications.error ?? "Please try again.")
        }
    }
}

struct AppLockSettingsScreen: View {
    @EnvironmentObject private var lock: AppLockService

    var body: some View {
        Form {
            Section {
                Toggle("Lock with \(lock.methodName)", isOn: Binding(
                    get: { lock.enabled },
                    set: { $0 ? lock.enable() : lock.disable() }
                ))
                .disabled(lock.isAuthenticating || (!lock.enabled && lock.availabilityMessage != nil))
            } footer: {
                Text(lock.availabilityMessage ??
                     "Ledgerly asks for \(lock.methodName) or your device passcode before showing your money.")
            }
            if lock.enabled {
                Section("Lock timing") {
                    Picker("Lock after leaving", selection: $lock.graceSeconds) {
                        Text("Immediately").tag(0.0)
                        Text("15 seconds").tag(15.0)
                        Text("1 minute").tag(60.0)
                        Text("5 minutes").tag(300.0)
                    }
                    Button("Lock now") { lock.lockNow() }
                }
            }
        }
        .navigationTitle("App lock")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WidgetSettingsScreen: View {
    @ObservedObject var store: LedgerStore
    @EnvironmentObject private var lock: AppLockService

    var body: some View {
        Form {
            Section("Monthly budget") {
                Label("Small and medium widgets", systemImage: "rectangle.grid.1x2.fill")
                Text("Touch and hold your Home Screen, choose Edit → Add Widget, then search for Ledgerly. Tap the budget widget to open your monthly budget.")
            }
            Section("Privacy and updates") {
                Text(lock.enabled
                     ? "Budget amounts are hidden in widgets while App lock is enabled."
                     : "The widget shows this account's saved monthly budget and spending.")
                Text("iOS controls refresh timing. Open Ledgerly to refresh cloud changes.")
                    .foregroundStyle(.secondary)
                if let message = store.budgetWidgetError {
                    Text(message).foregroundStyle(.secondary)
                    Button("Refresh budget widget") { store.refreshBudgetWidget() }
                }
            }
        }
        .navigationTitle("Home Screen widgets")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CloudSyncSettingsScreen: View {
    @ObservedObject var store: LedgerStore

    var body: some View {
        Form {
            Section("Sync status") {
                Label(store.syncStatus, systemImage: "icloud")
                    .font(.headline)
                if store.pendingCloudChanges > 0 {
                    LabeledContent("Waiting to sync", value: "\(store.pendingCloudChanges)")
                }
                if store.cloudSyncError != nil {
                    Text("Some changes couldn't sync. Check your connection and try again.").foregroundStyle(.secondary)
                    Button("Try again") { store.retryCloudSync() }
                } else if let message = store.syncBannerMessage {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            Section("Saved to your account") {
                Text("Your saved data is available on your signed-in devices. You can keep using Ledgerly offline.")
                Text("Offline changes sync when you reconnect.")
                    .foregroundStyle(.secondary)
                DisclosureGroup("What syncs") {
                    AccountSyncContents()
                }
            }
        }
        .navigationTitle("Data and sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacySettingsScreen: View {
    var body: some View {
        Form {
            Section("Your account") {
                Text("Your account keeps a copy of your saved data, including any locations attached to transactions.")
                Text("Without signing in, your data stays on this device. Signing in adds existing guest data to your account.")
                DisclosureGroup("What syncs") { AccountSyncContents() }
            }
            Section("On this device") {
                Text("Place-alert settings, permissions, visit history, personalised suggestions and unfinished shopping trips stay on this device.")
            }
            Section("Optional access") {
                NavigationLink { PermissionsScreen() } label: {
                    Label("Review permissions", systemImage: "hand.raised")
                }
            }
            Section {
                DisclosureGroup("Storage and deletion details") {
                    Text("Google Firebase provides account sign-in and cloud storage. Personal learning runs on your device.")
                    Text("Deleting your account removes its saved content. A record of the deletion is kept to prevent old devices from uploading it again.")
                    Text("Files you have exported or shared and copies on other devices need to be removed separately.")
                }
            }
        }
        .navigationTitle("Your data")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AccountSyncContents: View {
    var body: some View {
        Text("Transactions and their locations, budgets, events and shared expenses.")
        Text("Categories, payment methods, reminders, saved places, receipt photos and your custom profile photo.")
    }
}
