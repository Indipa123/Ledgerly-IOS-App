import SwiftUI
import FirebaseAuth

struct ChangeEmailScreen: View {
    @ObservedObject var auth: AuthSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var accountID: String?
    @State private var newEmail = ""
    @State private var confirmation = ""
    @State private var currentPassword = ""
    @State private var message: String?
    @State private var hasError = false
    @State private var isSending = false
    @State private var isChecking = false

    var body: some View {
        Form {
            if let user = auth.user, auth.hasEmailPasswordProvider {
                Section("Current address") {
                    Text(user.email ?? "Email unavailable")
                        .textSelection(.enabled)
                }
                if let pending = auth.pendingEmailChange {
                    Section {
                        Label("Verify your new address", systemImage: "envelope.badge")
                            .font(.headline)
                        Text(pending.newEmail).textSelection(.enabled)
                        Text("Requested \(pending.requestedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button {
                            Task { await checkStatus() }
                        } label: {
                            HStack {
                                Text("Check verification status")
                                if isChecking { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(auth.isBusy)
                    } footer: {
                        Text("Open the verification link sent to this address, then check the status here. If the link expired, request a fresh one below. If you need to sign in again after verifying, use the new email address and your existing password.")
                    }
                }
                Section {
                    TextField("New email", text: $newEmail)
                        .accessibilityLabel("New email address")
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Confirm new email", text: $confirmation)
                        .accessibilityLabel("Confirm new email address")
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Current password", text: $currentPassword)
                        .textContentType(.password)
                } header: {
                    Text("New address")
                } footer: {
                    Text("Your current password confirms your identity. The address changes only after you verify the new inbox. Your transactions and budgets stay with the same Ledgerly account.")
                }
                .disabled(auth.isBusy)
                Section {
                    Button {
                        Task { await sendRequest() }
                    } label: {
                        HStack {
                            Text("Send verification link")
                            if isSending { Spacer(); ProgressView() }
                        }
                        .frame(minHeight: 32)
                    }
                    .disabled(auth.isBusy || accountID == nil ||
                        newEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        confirmation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || currentPassword.isEmpty)
                }
                if let message {
                    Section {
                        Label(message, systemImage: hasError ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(hasError ? Color.red : Color.secondary)
                    }
                }
            } else {
                ContentUnavailableView("Email managed by your provider", systemImage: "person.crop.circle",
                    description: Text("Google-only accounts use the address supplied by Google. Return to your profile to review your sign-in details."))
            }
        }
        .navigationTitle("Change email")
        .navigationBarBackButtonHidden(auth.isBusy)
        .onAppear {
            accountID = auth.user?.uid
            if let pending = auth.pendingEmailChange {
                newEmail = pending.newEmail
                confirmation = pending.newEmail
            }
        }
        .onChange(of: auth.user?.uid) { _, _ in
            currentPassword = ""
            newEmail = ""
            confirmation = ""
            message = nil
            dismiss()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { currentPassword = "" }
            else if auth.pendingEmailChange != nil && !auth.isBusy {
                Task { await checkStatus() }
            }
        }
        .onDisappear { currentPassword = "" }
    }

    @MainActor
    private func sendRequest() async {
        guard let accountID else { return }
        message = nil
        isSending = true
        defer { isSending = false; currentPassword = "" }
        do {
            try await auth.requestEmailChange(newEmail: newEmail, confirmation: confirmation,
                                               currentPassword: currentPassword, expectedAccountID: accountID)
            hasError = false
            message = "Verification email sent. Open its link in your new inbox, then check the status here."
        } catch {
            hasError = true
            message = auth.accountErrorMessage(error)
        }
    }

    @MainActor
    private func checkStatus() async {
        guard let accountID, !auth.isBusy else { return }
        message = nil
        isChecking = true
        defer { isChecking = false }
        do {
            let applied = try await auth.checkEmailChange(expectedAccountID: accountID)
            hasError = false
            if applied {
                newEmail = ""
                confirmation = ""
                currentPassword = ""
                message = "Email updated. Use the new address the next time you sign in with email."
            } else {
                message = "The new address has not been confirmed yet. Open the link in your new inbox, then check again."
            }
        } catch {
            hasError = true
            message = auth.accountErrorMessage(error)
        }
    }
}
