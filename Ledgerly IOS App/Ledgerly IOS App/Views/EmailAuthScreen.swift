import SwiftUI

struct EmailAuthScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var auth: AuthSession
    let onSuccess: () -> Void
    var allowsRegistration: Bool
    var embeddedInNavigation: Bool
    var continueWithoutAccount: (() -> Void)?

    @State private var mode: Mode
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var showsPassword = false
    @State private var errorMessage: String?
    @State private var confirmationMessage: String?
    @State private var isSubmitting = false
    @FocusState private var focus: Field?

    private enum Mode: Equatable { case signIn, createAccount }
    private enum Field: Hashable { case email, password, confirmation }
    private var isWorking: Bool { auth.isBusy || isSubmitting }

    init(auth: AuthSession, onSuccess: @escaping () -> Void,
         allowsRegistration: Bool = true, startsWithRegistration: Bool = false,
         embeddedInNavigation: Bool = false, continueWithoutAccount: (() -> Void)? = nil) {
        self.auth = auth
        self.onSuccess = onSuccess
        self.allowsRegistration = allowsRegistration
        self.embeddedInNavigation = embeddedInNavigation
        self.continueWithoutAccount = continueWithoutAccount
        _mode = State(initialValue: startsWithRegistration && allowsRegistration ? .createAccount : .signIn)
    }

    var body: some View {
        Group {
            if embeddedInNavigation { accountContent }
            else { NavigationStack { accountContent } }
        }
        .tint(Palette.dashboardAccent)
        .interactiveDismissDisabled(isWorking)
    }

    private var accountContent: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(mode == .signIn ? "Welcome back" : "Your money, made clear")
                            .font(.largeTitle.bold())
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(mode == .signIn ? "Sign in to continue to your ledger." : "Create your Ledgerly account.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .id("account.heading")

                    HStack(spacing: 14) {
                        Image(systemName: "chart.pie.fill")
                            .font(.title2)
                            .frame(width: 52, height: 52)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 17))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Keep your ledger with you").font(.headline)
                            Text("Your spending, budgets and plans, together.")
                                .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.plum, in: RoundedRectangle(cornerRadius: 24))

                    VStack(alignment: .leading, spacing: 18) {
                        Text(mode == .signIn ? "Sign in with email" : "Start with your email")
                            .font(.subheadline).foregroundStyle(.secondary)
                        AccountField(title: "Email") {
                            TextField("Email address", text: $email)
                                .keyboardType(.emailAddress)
                                .textContentType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .email)
                                .submitLabel(.next)
                                .onSubmit { focus = .password }
                                .accessibilityLabel("Email")
                                .accessibilityIdentifier("auth.email")
                        }
                        AccountField(title: "Password") {
                            HStack(spacing: 12) {
                                Group {
                                    if showsPassword { TextField("Enter your password", text: $password) }
                                    else { SecureField("Enter your password", text: $password) }
                                }
                                .textContentType(mode == .signIn ? .password : .newPassword)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .password)
                                .submitLabel(mode == .createAccount ? .next : .go)
                                .onSubmit {
                                    if mode == .createAccount { focus = .confirmation }
                                    else { Task { await submit() } }
                                }
                                .accessibilityLabel("Password")
                                .accessibilityIdentifier("auth.password")
                                Button { showsPassword.toggle() } label: {
                                    Image(systemName: showsPassword ? "eye.slash" : "eye")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(showsPassword ? "Hide password" : "Show password")
                            }
                        }
                        if mode == .createAccount {
                            AccountField(title: "Confirm password") {
                                SecureField("Enter your password again", text: $confirmation)
                                    .textContentType(.newPassword)
                                    .focused($focus, equals: .confirmation)
                                    .submitLabel(.go)
                                    .onSubmit { Task { await submit() } }
                                    .accessibilityLabel("Confirm password")
                            }
                            Text("Use at least six characters.").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Button("Forgot password?") { focus = nil; Task { await resetPassword() } }
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 34, alignment: .trailing)
                        }
                    }
                    .disabled(isWorking)

                    if let message = errorMessage ?? auth.error {
                        Label(message, systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline).foregroundStyle(Palette.dashboardAccent)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("auth.error")
                    }
                    if let confirmationMessage {
                        Label(confirmationMessage, systemImage: "envelope.badge")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 14) {
                        Button {
                            focus = nil
                            Task { await submit() }
                        } label: {
                            HStack(spacing: 10) {
                                if isSubmitting { ProgressView().tint(.white) }
                                Text(mode == .signIn ? "Sign in" : "Create account")
                            }
                        }
                        .buttonStyle(AccountPrimaryButtonStyle())
                        .disabled(isWorking || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                        .accessibilityIdentifier("auth.submit")
                        if allowsRegistration {
                            GoogleAccountButton {
                                focus = nil
                                errorMessage = nil
                                confirmationMessage = nil
                                password = ""
                                confirmation = ""
                                auth.signInWithGoogle(onSuccess: onSuccess)
                            }
                            .disabled(isWorking)
                        }
                        if auth.isBusy && !isSubmitting {
                            ProgressView("Signing in…").font(.subheadline)
                        }
                    }

                    VStack(spacing: 12) {
                        if allowsRegistration {
                            HStack(spacing: 6) {
                                Text(mode == .signIn ? "New here?" : "Already have an account?")
                                    .foregroundStyle(.secondary)
                                Button(mode == .signIn ? "Create account" : "Sign in") {
                                    mode = mode == .signIn ? .createAccount : .signIn
                                }.fontWeight(.semibold)
                            }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(isWorking)
                        }
                        if let continueWithoutAccount {
                            Button("Explore without an account", action: continueWithoutAccount)
                                .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                                .disabled(isWorking)
                        }
                        if allowsRegistration {
                            Text("Your first sign-in also saves any entries already on this device to your account.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.cream.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .navigationBarBackButtonHidden(isWorking)
            .toolbar {
                if !embeddedInNavigation {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.disabled(isWorking)
                    }
                }
            }
            .onChange(of: mode) { _, _ in
                password = ""
                confirmation = ""
                showsPassword = false
                errorMessage = nil
                confirmationMessage = nil
                auth.error = nil
                focus = nil
                scroll.scrollTo("account.heading", anchor: .top)
            }
        }
    }

    @MainActor
    private func submit() async {
        guard !isWorking else { return }
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
        guard !isWorking else { return }
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
