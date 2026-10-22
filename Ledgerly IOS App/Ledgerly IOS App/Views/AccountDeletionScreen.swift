import SwiftUI
import FirebaseAuth

struct AccountDeletionScreen: View {
    @ObservedObject var auth: AuthSession
    @ObservedObject var store: LedgerStore
    @EnvironmentObject private var trips: ShoppingTripStore
    let accountID: String
    var recovering = false
    @State private var password = ""
    @State private var method: AccountDeletionVerification = .password
    @State private var acknowledged = false
    @State private var confirming = false
    @State private var showingEmailSignIn = false

    private var verificationMethod: AccountDeletionVerification {
        if auth.hasEmailPasswordProvider && auth.hasGoogleProvider { return method }
        return auth.hasEmailPasswordProvider ? .password : .google
    }

    var body: some View {
        Form {
            Section {
                Label(recovering ? "Account deletion pending" : "Delete your Ledgerly account",
                      systemImage: "person.crop.circle.badge.minus").font(.headline)
                if let email = auth.user?.email { Text(email).textSelection(.enabled) }
                Text("This permanently deletes your Ledgerly account and its saved data, including receipts, places and profile photo. It also clears this account’s data and settings from this device.")
                Text("Other devices may retain local copies; remove Ledgerly's account data on those devices separately. Files you already exported or shared cannot be recalled.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Your Google account is not deleted.")
                    .font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("Deletion details") {
                    Text("This includes guest data previously added to the account. A record of the deletion is kept to prevent old devices from uploading data again.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if auth.user?.uid == accountID {
                Section("Verify your identity") {
                    if auth.hasEmailPasswordProvider && auth.hasGoogleProvider {
                        Picker("Verify with", selection: $method) {
                            ForEach(AccountDeletionVerification.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    if verificationMethod == .password {
                        SecureField("Current password", text: $password).textContentType(.password)
                    } else {
                        Text("Continue with the same Google account to verify this deletion.")
                    }
                    if !recovering {
                        Toggle("I understand this cannot be undone", isOn: $acknowledged)
                    }
                    Button(recovering ? "Verify and retry deletion" : "Delete my account", role: .destructive) {
                        confirming = true
                    }
                    .disabled(auth.isBusy || (!recovering && !acknowledged) || (verificationMethod == .password && password.isEmpty))
                }
                .disabled(auth.isBusy)
            } else {
                Section("Sign-in required") {
                    Text("Deletion has not been confirmed. Sign in to the same account to retry. Continuing signed out keeps this request for the next time that account is opened.")
                    if auth.pendingAccountDeletion?.phase == .localRemoved {
                        Button("Continue signed out") { auth.continueSignedOutAfterDeletion() }
                            .disabled(auth.isBusy)
                    } else {
                        Button("Sign in with Google") { auth.signInWithGoogle() }.disabled(auth.isBusy)
                        Button("Sign in with email") { showingEmailSignIn = true }.disabled(auth.isBusy)
                    }
                }
            }
            if auth.isBusy {
                Section { ProgressView(auth.deletionProgress.isEmpty ? "Working…" : auth.deletionProgress) }
            }
            if let error = auth.deletionError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                    if recovering { Text("New uploads are paused. Keep this app installed and reconnect to retry.").font(.footnote) }
                }
            }
        }
        .navigationTitle(recovering ? "Finish deletion" : "Delete account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { method = auth.hasEmailPasswordProvider ? .password : .google }
        .sheet(isPresented: $showingEmailSignIn) {
            EmailAuthScreen(auth: auth, onSuccess: { showingEmailSignIn = false }, allowsRegistration: false)
        }
        .confirmationDialog("Permanently delete this Ledgerly account?", isPresented: $confirming) {
            Button(recovering ? "Continue deletion" : "Delete account and data", role: .destructive) {
                let secret = password
                let selectedMethod = verificationMethod
                password = ""
                Task {
                    do { try await auth.deleteAccount(expectedAccountID: accountID, password: secret,
                        method: selectedMethod, store: store, trips: trips) }
                    catch { /* AuthSession retains the recovery status and user-facing error. */ }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("There is no Undo. Keep Ledgerly open while it removes your account. If interrupted, verification and cleanup can be retried.")
        }
    }
}
