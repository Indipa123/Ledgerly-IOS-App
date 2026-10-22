import SwiftUI
import FirebaseAuth

struct ChangePasswordScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var auth: AuthSession
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?
    @State private var didUpdate = false

    var body: some View {
        Form {
            Section {
                SecureField("Current password", text: $currentPassword)
                    .textContentType(.password)
                SecureField("New password", text: $newPassword)
                    .textContentType(.newPassword)
                SecureField("Confirm new password", text: $confirmation)
                    .textContentType(.newPassword)
            } footer: {
                Text("Use at least six characters. Ledgerly verifies your current password before saving the new one.")
            }
            .disabled(auth.isBusy)
            Section {
                Button {
                    Task { await changePassword() }
                } label: {
                    HStack {
                        Text("Change password")
                        if auth.isBusy { Spacer(); ProgressView() }
                    }
                }
                .disabled(auth.isBusy || currentPassword.isEmpty || newPassword.isEmpty || confirmation.isEmpty)
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Change password")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(auth.isBusy)
        .alert("Password updated", isPresented: $didUpdate) {
            Button("Done") { dismiss() }
        } message: {
            Text("Use your new password the next time you sign in with email.")
        }
        .onChange(of: auth.user?.uid) { _, _ in
            clearPasswords()
            dismiss()
        }
        .onDisappear { clearPasswords() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clearPasswords() }
        }
    }

    @MainActor
    private func changePassword() async {
        errorMessage = nil
        do {
            try await auth.changePassword(currentPassword: currentPassword, newPassword: newPassword,
                                          confirmation: confirmation)
            clearPasswords()
            didUpdate = true
        } catch {
            errorMessage = auth.accountErrorMessage(error)
        }
    }

    private func clearPasswords() {
        currentPassword = ""
        newPassword = ""
        confirmation = ""
    }
}
