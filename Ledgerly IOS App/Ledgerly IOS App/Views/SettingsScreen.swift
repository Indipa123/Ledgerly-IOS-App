import SwiftUI
import GoogleSignInSwift
import FirebaseAuth

struct SettingsScreen: View {
    @ObservedObject var store: LedgerStore
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var lock: AppLockService
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
                NavigationLink("Categories") { CategoriesScreen(store: store) }
                NavigationLink("Payment methods") { PaymentMethodsScreen(store: store) }
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
    }
}
