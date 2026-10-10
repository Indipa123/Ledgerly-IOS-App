import SwiftUI
import GoogleSignInSwift
import FirebaseAuth

struct SettingsScreen: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var notifications: LedgerNotificationService
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var lock: AppLockService
    @Environment(\.openURL) private var openURL
    @AppStorage("appearance") private var appearance = 0
    var body: some View {
        Form {
            Section("Profile") {
                if let user = auth.user {
                    LabeledContent("Signed in", value: user.displayName ?? user.email ?? "Google account")
                    Button("Sign out") { auth.signOut() }
                } else {
                    GoogleSignInButton(action: { auth.signInWithGoogle() })
                        .frame(height: 50)
                        .disabled(auth.isBusy)
                }
                LabeledContent("Currency", value: "Sri Lankan rupee")
                LabeledContent("Storage", value: store.syncStatus)
            }
            Section("Manage") {
                NavigationLink { LearnedCategoriesScreen(store: store) } label: {
                    settingsRow("Learned categories", symbol: "sparkle.magnifyingglass", color: Palette.iconPlum)
                }
                NavigationLink { CategoriesScreen(store: store) } label: {
                    settingsRow("Categories", symbol: "square.grid.2x2.fill", color: Palette.cranberry)
                }
                NavigationLink { PaymentMethodsScreen(store: store) } label: {
                    settingsRow("Payment methods", symbol: "creditcard.fill", color: Palette.iconPlum)
                }
                NavigationLink { RemindersScreen(store: store) } label: {
                    settingsRow("Reminders", symbol: "bell.fill", color: Palette.coral)
                }
            }
            Section("Notifications") {
                Toggle("Budget alerts", isOn: Binding(
                    get: { notifications.budgetAlertsEnabled },
                    set: { enabled in Task { await notifications.setBudgetAlertsEnabled(enabled) } }
                ))
                LabeledContent("Permission", value: notifications.permissionText)
                if notifications.permissionText == "Denied in iPhone Settings" {
                    Button("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                Text("Budget alerts appear once after spending passes 80% or 100% of this month's budget. Reminders are scheduled only after you allow notifications.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
                .pickerStyle(.segmented)
                Text("System follows your iPhone's appearance setting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("App lock") {
                Toggle("Lock with \(lock.methodName)", isOn: Binding(
                    get: { lock.enabled },
                    set: { $0 ? lock.enable() : lock.disable() }
                ))
                .disabled(!lock.enabled && lock.availabilityMessage != nil)
                if let explanation = lock.availabilityMessage, !lock.enabled {
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Ledgerly asks for \(lock.methodName) or your device passcode before showing your money.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if lock.enabled {
                    Picker("Lock after leaving", selection: $lock.graceSeconds) {
                        Text("Immediately").tag(0.0)
                        Text("15 seconds").tag(15.0)
                        Text("1 minute").tag(60.0)
                        Text("5 minutes").tag(300.0)
                    }
                    Button("Lock now") { lock.lockNow() }
                }
            }
            Section("Privacy") {
                Text("Signed-in transactions and monthly budgets are stored in Firestore and cached on this device. Guest entries stay local until the first Google sign-in.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task { await notifications.refreshPermission() }
    }

    private func settingsRow(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            LedgerIconTile(icon: .init(symbol: symbol, color: color), size: 38)
            Text(title)
        }
    }
}
