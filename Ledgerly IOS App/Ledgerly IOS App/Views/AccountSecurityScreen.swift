import SwiftUI
import FirebaseAuth

struct AccountSecurityScreen: View {
    @ObservedObject var auth: AuthSession
    @ObservedObject var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var hasError = false

    var body: some View {
        Form {
            if let user = auth.user {
                Section("Sign-in details") {
                    LabeledContent("Method", value: auth.signInMethod)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Email address").font(.subheadline).foregroundStyle(.secondary)
                        Text(user.email ?? "Not provided").textSelection(.enabled)
                    }.padding(.vertical, 4)
                }
                if auth.hasEmailPasswordProvider {
                    Section {
                        Label(user.isEmailVerified ? "Email verified" : "Email not verified",
                              systemImage: user.isEmailVerified ? "checkmark.seal" : "envelope.badge")
                        if !user.isEmailVerified {
                            Button("Send verification email") { Task { await sendVerification() } }
                            Button("Check verification status") { Task { await checkVerification() } }
                        }
                    } header: {
                        Text("Email verification")
                    } footer: {
                        if !user.isEmailVerified {
                            Text("Open the verification link sent to your inbox, then check the status here.")
                        }
                    }
                    .disabled(auth.isBusy)
                    Section("Manage sign-in") {
                        NavigationLink { ChangeEmailScreen(auth: auth) } label: {
                            SettingsMenuRow(title: "Change email", subtitle: auth.pendingEmailChange.map {
                                "Verification requested for \($0.newEmail)"
                            } ?? "Verify a new email address", symbol: "envelope.fill")
                        }
                        NavigationLink { ChangePasswordScreen(auth: auth) } label: {
                            SettingsMenuRow(title: "Change password", subtitle: "Confirm your current password",
                                            symbol: "key.fill")
                        }
                    }
                    .disabled(auth.isBusy)
                } else {
                    Section {
                        Label("Managed by your sign-in provider", systemImage: "lock.shield")
                        Text("Your provider manages your email address and password. Your display name can be edited in Ledgerly.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let message {
                    Section {
                        Label(message, systemImage: hasError ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(hasError ? Color.red : Color.primary)
                    }
                }
                Section {
                    NavigationLink {
                        AccountDeletionScreen(auth: auth, store: store, accountID: user.uid)
                    } label: {
                        Label("Delete account", systemImage: "person.crop.circle.badge.minus")
                            .foregroundStyle(.red)
                    }
                    .disabled(auth.isBusy)
                } header: {
                    Text("Delete account")
                } footer: {
                    Text("Permanently remove your Ledgerly sign-in and its cloud and local data.")
                }
            }
        }
        .navigationTitle("Account security")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: auth.user?.uid) { _, _ in dismiss() }
    }

    @MainActor
    private func sendVerification() async {
        message = nil
        do {
            try await auth.sendVerificationEmail()
            hasError = false
            message = "Verification email sent. Open its link, then check the status here."
        } catch {
            hasError = true
            message = auth.accountErrorMessage(error)
        }
    }

    @MainActor
    private func checkVerification() async {
        message = nil
        do {
            try await auth.refreshEmailVerification()
            hasError = false
            message = auth.user?.isEmailVerified == true ? "Your email is verified." :
                "Still waiting for verification. Open the link in your inbox, then check again."
        } catch {
            hasError = true
            message = auth.accountErrorMessage(error)
        }
    }
}
