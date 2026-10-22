import SwiftUI
import FirebaseAuth

struct SignOutReviewScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    @ObservedObject var auth: AuthSession
    let accountID: String

    private var hasUnconfirmedSync: Bool { store.hasUnconfirmedSync(for: accountID) }

    var body: some View {
        Form {
            if let user = auth.user, user.uid == accountID {
                Section("Account") {
                    if let name = user.displayName, !name.isEmpty {
                        Text(name).font(.headline)
                    }
                    if let email = user.email {
                        Text(email).foregroundStyle(.secondary)
                    }
                }
                Section("Cloud sync") {
                    Label(store.syncStatus, systemImage: hasUnconfirmedSync ?
                          "icloud.and.arrow.up" : "checkmark.icloud")
                        .font(.headline)
                    if store.pendingCloudChanges > 0 {
                        LabeledContent("Records waiting to sync", value: "\(store.pendingCloudChanges)")
                    }
                    Text(store.signOutSyncMessage(for: accountID))
                    if hasUnconfirmedSync && !store.uploadingExistingData {
                        Button("Stay signed in and retry sync") {
                            guard auth.user?.uid == accountID else { return }
                            store.retryCloudSync()
                            dismiss()
                        }
                        .disabled(auth.isBusy)
                    }
                }
                Section("After signing out") {
                    Text("Your account's saved data stays on this device and is hidden while signed out. Sign back in to the same account to view it and retry syncing.")
                }
                Section {
                    Button(hasUnconfirmedSync ? "Sign out anyway" : "Sign out", role: .destructive) {
                        guard auth.user?.uid == accountID else { return }
                        auth.signOut()
                    }
                    .disabled(auth.isBusy)
                }
            } else {
                ContentUnavailableView("Account changed", systemImage: "person.crop.circle",
                                       description: Text("Close this review and return to Settings."))
            }
        }
        .navigationTitle("Sign out")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .onChange(of: auth.user?.uid) { _, uid in
            if uid != accountID { dismiss() }
        }
    }
}
