import SwiftUI

struct EmailAuthScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var auth: AuthSession
    let onSuccess: () -> Void
    var allowsRegistration = true

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?
    @State private var confirmationMessage: String?
    @State private var isSubmitting = false

    private enum Mode: Int {
        case signIn, createAccount
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if allowsRegistration { Picker("Account action", selection: $mode) {
                        Text("Sign in").tag(Mode.signIn)
                        Text("Create account").tag(Mode.createAccount)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mode) { _, _ in
                        password = ""
                        confirmation = ""
                        errorMessage = nil
                        confirmationMessage = nil
                    }
                    }
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(mode == .signIn ? .password : .newPassword)
                    if mode == .createAccount {
                        SecureField("Confirm password", text: $confirmation)
                            .textContentType(.newPassword)
                    }
                } footer: {
                    if mode == .createAccount {
                        Text("Use at least six characters for your password.")
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting { ProgressView().padding(.trailing, 6) }
                            Text(mode == .signIn ? "Sign in" : "Create account")
                                .font(.headline)
                            Spacer()
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(auth.isBusy)

                    if mode == .signIn {
                        Button("Forgot password?") {
                            Task { await resetPassword() }
                        }
                        .disabled(auth.isBusy)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if let confirmationMessage {
                    Section {
                        Label(confirmationMessage, systemImage: "envelope.badge")
                    }
                }
                Section {
                    Text("When you sign in to your first account on this device, Ledgerly uploads your existing local transactions and budgets to it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Email account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(Palette.cranberry)
    }

    @MainActor
    private func submit() async {
        errorMessage = nil
        confirmationMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            switch mode {
            case .signIn:
                try await auth.signInWithEmail(email, password: password)
            case .createAccount:
                try await auth.createEmailAccount(email, password: password,
                                                  confirmation: confirmation)
            }
            password = ""
            confirmation = ""
            onSuccess()
        } catch {
            errorMessage = auth.accountErrorMessage(error)
        }
    }

    @MainActor
    private func resetPassword() async {
        errorMessage = nil
        confirmationMessage = nil
        do {
            try await auth.sendPasswordReset(to: email)
            confirmationMessage = "If an account exists for this email, check your inbox for a password reset link."
        } catch {
            errorMessage = auth.accountErrorMessage(error)
        }
    }
}
