import Combine
import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import UIKit

private enum EmailAuthError: LocalizedError {
    case unavailable
    case busy
    case invalidEmail
    case missingPassword
    case shortPassword
    case passwordMismatch
    case notSignedIn
    case invalidDisplayName
    case passwordUnchanged
    case passwordProviderRequired
    case accountChanged
    case accountActionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Account sign-in is currently unavailable. Please try again later."
        case .busy: "Another account action is in progress. Please try again."
        case .invalidEmail: "Enter a valid email address."
        case .missingPassword: "Enter your password."
        case .shortPassword: "Use at least six characters for your password."
        case .passwordMismatch: "The passwords do not match."
        case .notSignedIn: "Sign in to manage your account."
        case .invalidDisplayName: "Enter a display name between 1 and 80 characters."
        case .passwordUnchanged: "Choose a new password that differs from your current password."
        case .passwordProviderRequired: "This account's password is managed by its sign-in provider."
        case .accountChanged: "Your signed-in account changed. Open this screen again to continue."
        case .accountActionFailed(let message): message
        }
    }
}

@MainActor
final class AuthSession: ObservableObject {
    @Published private(set) var user: FirebaseAuth.User? {
        didSet { restorePendingEmailChange(); restoreAccountDeletion() }
    }
    @Published private(set) var pendingAccountDeletion: PendingAccountDeletion?
    @Published private(set) var deletionProgress = ""
    @Published private(set) var deletionError: String?
    @Published private(set) var pendingEmailChange: PendingEmailChange?
    @Published private(set) var isReady = false
    @Published private(set) var isBusy = false
    @Published var error: String?

    private var listener: AuthStateDidChangeListenerHandle?
    private var deletionObserver: AnyCancellable?
    private var ignoredOrphanedDeletion = false
    private static var deletionIsRunning = false

    init() {
        deletionObserver = NotificationCenter.default.publisher(for: .ledgerlyAccountDeletionChanged)
            .sink { [weak self] _ in
                Task { @MainActor in self?.restoreAccountDeletion() }
            }
    }

    var hasGoogleProvider: Bool {
        user?.providerData.contains { $0.providerID == GoogleAuthProviderID } == true
    }

    private func restoreAccountDeletion() {
        do {
            if let uid = user?.uid { pendingAccountDeletion = try AccountDeletionJournal.shared.load(uid) }
            else if isReady && !ignoredOrphanedDeletion { pendingAccountDeletion = try AccountDeletionJournal.shared.firstPending() }
            else { pendingAccountDeletion = nil }
        } catch {
            if let uid = user?.uid, AccountDeletionJournal.shared.contains(uid) {
                pendingAccountDeletion = .init(accountID: uid, requestedAt: .now, includesClaimedGuest: false)
            }
            deletionError = "Could not check the deletion request. Keep Ledgerly installed and try again."
        }
    }

    func continueSignedOutAfterDeletion() {
        guard user == nil, !isBusy else { return }
        // Keep the request. A missing session is not proof that Firebase deleted the login.
        ignoredOrphanedDeletion = true
        pendingAccountDeletion = nil
    }

    func deleteAccount(expectedAccountID uid: String, password: String,
                       method: AccountDeletionVerification, store: LedgerStore,
                       trips: ShoppingTripStore) async throws {
        guard !isBusy, !Self.deletionIsRunning else { throw AccountDeletionError.busy }
        guard user?.uid == uid, Auth.auth().currentUser?.uid == uid else { throw AccountDeletionError.accountChanged }
        isBusy = true
        Self.deletionIsRunning = true
        deletionError = nil
        defer { isBusy = false; Self.deletionIsRunning = false }
        do {
            let request = try AccountDeletionJournal.shared.load(uid) ?? PendingAccountDeletion(
                accountID: uid, requestedAt: .now,
                includesClaimedGuest: UserDefaults.standard.string(forKey: "ledgerly.guestClaimedBy") == uid)
            let client = FirebaseAccountDeletionClient(uid: uid, password: password, method: method,
                store: store, trips: trips, progress: { [weak self] in self?.deletionProgress = $0 })
            try await AccountDeletionWorkflow.run(request, client: client)
            ignoredOrphanedDeletion = true
            pendingAccountDeletion = nil
            if Auth.auth().currentUser == nil {
                GIDSignIn.sharedInstance.signOut()
                user = nil
            }
            deletionProgress = "Account deleted"
        } catch {
            deletionError = accountErrorMessage(error)
            restoreAccountDeletion()
            throw error
        }
    }

    func updateCustomPhoto(_ data: Data?, expectedAccountID: String) throws {
        guard user?.uid == expectedAccountID, Auth.auth().currentUser?.uid == expectedAccountID,
              !AccountDeletionJournal.shared.contains(expectedAccountID) else { throw EmailAuthError.accountChanged }
        try AccountPhotoStore.save(data, uid: expectedAccountID)
        objectWillChange.send()
    }

    var profilePhotoURL: URL? {
        guard let user else { return nil }
        return user.photoURL ?? user.providerData.compactMap(\.photoURL).first
    }

    var profileName: String {
        let name = user?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? (user == nil ? "Welcome to Ledgerly" : "Your account") : name
    }

    var signInMethod: String {
        let google = user?.providerData.contains { $0.providerID == GoogleAuthProviderID } == true
        if google && hasEmailPasswordProvider { return "Google and email" }
        if google { return "Signed in with Google" }
        return hasEmailPasswordProvider ? "Signed in with email" : "Ledgerly account"
    }

    var hasEmailPasswordProvider: Bool {
        guard let user, user.email != nil else { return false }
        return user.providerData.isEmpty ||
            user.providerData.contains { $0.providerID == EmailAuthProviderID }
    }

    func start() {
        guard listener == nil else { return }
        guard FirebaseApp.app() != nil else { isReady = true; return }
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
                self?.isReady = true
                self?.restoreAccountDeletion()
            }
        }
    }

    func signInWithGoogle(onSuccess: @escaping () -> Void = {}) {
        guard !isBusy else { return }
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            error = "Google sign-in is currently unavailable. Please try again later."
            return
        }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            error = "Could not open Google sign-in. Please try again."
            return
        }

        var presenter = root
        while let next = presenter.presentedViewController { presenter = next }
        isBusy = true
        error = nil
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { [weak self] result, signInError in
            Task { @MainActor in
                guard let self else { return }
                defer { self.isBusy = false }
                if signInError != nil {
                    self.error = "Google sign-in didn't finish. Please try again."
                    return
                }
                guard let googleUser = result?.user,
                      let idToken = googleUser.idToken?.tokenString else {
                    self.error = "Google sign-in didn't finish. Please try again."
                    return
                }
                let credential = GoogleAuthProvider.credential(
                    withIDToken: idToken,
                    accessToken: googleUser.accessToken.tokenString
                )
                do {
                    let authResult = try await Auth.auth().signIn(with: credential)
                    self.user = authResult.user
                    onSuccess()
                } catch {
                    self.error = self.accountErrorMessage(error)
                }
            }
        }
    }

    func signInWithEmail(_ email: String, password: String) async throws {
        guard FirebaseApp.app() != nil else { throw EmailAuthError.unavailable }
        guard !isBusy else { throw EmailAuthError.busy }
        let cleanEmail = try validatedEmail(email)
        guard !password.isEmpty else { throw EmailAuthError.missingPassword }
        isBusy = true
        defer { isBusy = false }
        let result = try await Auth.auth().signIn(withEmail: cleanEmail, password: password)
        user = result.user
    }

    func createEmailAccount(_ email: String, password: String,
                            confirmation: String) async throws {
        guard FirebaseApp.app() != nil else { throw EmailAuthError.unavailable }
        guard !isBusy else { throw EmailAuthError.busy }
        let cleanEmail = try validatedEmail(email)
        guard password.count >= 6 else { throw EmailAuthError.shortPassword }
        guard password == confirmation else { throw EmailAuthError.passwordMismatch }
        isBusy = true
        defer { isBusy = false }
        let result = try await Auth.auth().createUser(withEmail: cleanEmail, password: password)
        user = result.user
    }

    func sendPasswordReset(to email: String) async throws {
        guard FirebaseApp.app() != nil else { throw EmailAuthError.unavailable }
        guard !isBusy else { throw EmailAuthError.busy }
        let cleanEmail = try validatedEmail(email)
        isBusy = true
        defer { isBusy = false }
        try await Auth.auth().sendPasswordReset(withEmail: cleanEmail)
    }

    func sendVerificationEmail() async throws {
        guard FirebaseApp.app() != nil else { throw EmailAuthError.unavailable }
        guard !isBusy else { throw EmailAuthError.busy }
        guard let currentUser = Auth.auth().currentUser else { throw EmailAuthError.notSignedIn }
        isBusy = true
        defer { isBusy = false }
        try await currentUser.sendEmailVerification()
    }

    func refreshEmailVerification() async throws {
        guard FirebaseApp.app() != nil else { throw EmailAuthError.unavailable }
        guard !isBusy else { throw EmailAuthError.busy }
        guard let currentUser = Auth.auth().currentUser else { throw EmailAuthError.notSignedIn }
        let userID = currentUser.uid
        isBusy = true
        defer { isBusy = false }
        try await currentUser.reload()
        guard Auth.auth().currentUser?.uid == userID else { return }
        user = Auth.auth().currentUser
    }

    func updateDisplayName(_ name: String, expectedAccountID: String) async throws {
        guard FirebaseApp.app() != nil else { throw EmailAuthError.unavailable }
        guard !isBusy else { throw EmailAuthError.busy }
        guard let currentUser = Auth.auth().currentUser else { throw EmailAuthError.notSignedIn }
        guard currentUser.uid == user?.uid, currentUser.uid == expectedAccountID else {
            throw EmailAuthError.accountChanged
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(cleanName.count) else { throw EmailAuthError.invalidDisplayName }
        isBusy = true
        defer { isBusy = false }
        let request = currentUser.createProfileChangeRequest()
        request.displayName = cleanName
        do {
            try await request.commitChanges()
            guard Auth.auth().currentUser?.uid == currentUser.uid else { throw EmailAuthError.accountChanged }
            user = Auth.auth().currentUser
        } catch {
            throw accountActionError(error)
        }
    }

    func changePassword(currentPassword: String, newPassword: String,
                        confirmation: String) async throws {
        guard FirebaseApp.app() != nil else { throw EmailAuthError.unavailable }
        guard !isBusy else { throw EmailAuthError.busy }
        guard let currentUser = Auth.auth().currentUser,
              let email = currentUser.email else { throw EmailAuthError.notSignedIn }
        guard currentUser.uid == user?.uid else { throw EmailAuthError.accountChanged }
        guard hasEmailPasswordProvider else { throw EmailAuthError.passwordProviderRequired }
        guard !currentPassword.isEmpty else { throw EmailAuthError.missingPassword }
        guard newPassword.count >= 6 else { throw EmailAuthError.shortPassword }
        guard newPassword == confirmation else { throw EmailAuthError.passwordMismatch }
        guard newPassword != currentPassword else { throw EmailAuthError.passwordUnchanged }
        isBusy = true
        defer { isBusy = false }
        do {
            let credential = EmailAuthProvider.credential(withEmail: email, password: currentPassword)
            _ = try await currentUser.reauthenticate(with: credential)
            guard Auth.auth().currentUser?.uid == currentUser.uid else { throw EmailAuthError.accountChanged }
            try await currentUser.updatePassword(to: newPassword)
            guard Auth.auth().currentUser?.uid == currentUser.uid else { throw EmailAuthError.accountChanged }
            user = Auth.auth().currentUser
        } catch {
            throw accountActionError(error)
        }
    }

    func requestEmailChange(newEmail: String, confirmation: String, currentPassword: String,
                            expectedAccountID: String) async throws {
        guard FirebaseApp.app() != nil else { throw EmailAuthError.unavailable }
        guard !isBusy else { throw EmailAuthError.busy }
        guard user?.uid == expectedAccountID else { throw EmailAuthError.accountChanged }
        isBusy = true
        defer { isBusy = false }
        do {
            let pending = try await EmailChangeWorkflow.request(newEmail: newEmail,
                confirmation: confirmation, password: currentPassword,
                expectedAccountID: expectedAccountID, client: FirebaseEmailChangeClient())
            guard Auth.auth().currentUser?.uid == expectedAccountID else { throw EmailAuthError.accountChanged }
            // Only the requested address and timestamp are saved, never the password.
            let data = try JSONEncoder().encode(pending)
            UserDefaults.standard.set(data, forKey: pendingEmailKey(expectedAccountID))
            pendingEmailChange = pending
            user = Auth.auth().currentUser
        } catch {
            throw accountActionError(error)
        }
    }

    @discardableResult
    func checkEmailChange(expectedAccountID: String) async throws -> Bool {
        guard FirebaseApp.app() != nil else { throw EmailAuthError.unavailable }
        guard !isBusy else { throw EmailAuthError.busy }
        guard user?.uid == expectedAccountID else { throw EmailAuthError.accountChanged }
        guard let pending = pendingEmailChange else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let applied = try await EmailChangeWorkflow.check(pending,
                expectedAccountID: expectedAccountID, client: FirebaseEmailChangeClient())
            guard Auth.auth().currentUser?.uid == expectedAccountID else { throw EmailAuthError.accountChanged }
            user = Auth.auth().currentUser
            return applied
        } catch {
            throw accountActionError(error)
        }
    }

    private func pendingEmailKey(_ uid: String) -> String { "ledgerly.pendingEmailChange.\(uid)" }

    private func restorePendingEmailChange() {
        guard let user else { pendingEmailChange = nil; return }
        let key = pendingEmailKey(user.uid)
        guard let data = UserDefaults.standard.data(forKey: key),
              let pending = try? JSONDecoder().decode(PendingEmailChange.self, from: data) else {
            pendingEmailChange = nil
            return
        }
        if let email = user.email, EmailChangeWorkflow.matches(email, pending.newEmail) {
            UserDefaults.standard.removeObject(forKey: key)
            pendingEmailChange = nil
        } else {
            pendingEmailChange = pending
        }
    }

    func accountErrorMessage(_ error: Error) -> String {
        if error is EmailAuthError || error is EmailChangeError || error is AccountDeletionError {
            return error.localizedDescription
        }
        if let mapped = accountActionError(error) as? EmailAuthError { return mapped.localizedDescription }
        return "Could not complete this account action. Please try again."
    }

    private func accountActionError(_ error: Error) -> Error {
        let detail = error as NSError
        guard detail.domain == AuthErrors.domain, let code = AuthErrorCode(rawValue: detail.code) else { return error }
        let message: String
        switch code {
        case .wrongPassword, .invalidCredential:
            message = "Could not verify your current password. Check it and try again."
        case .networkError:
            message = "Could not reach the account service. Check your internet connection and try again."
        case .tooManyRequests:
            message = "Too many attempts. Wait a moment before trying again."
        case .weakPassword:
            message = "Choose a stronger password and try again."
        case .requiresRecentLogin, .invalidUserToken, .userTokenExpired:
            message = "Sign in again before changing your account details."
        case .userDisabled:
            message = "This account has been disabled."
        case .invalidEmail:
            message = "Enter a valid email address."
        case .emailAlreadyInUse:
            message = "That email address cannot be used for this account. Choose another address."
        case .userMismatch:
            message = "The credentials belong to a different account. Sign in again to continue."
        default:
            return EmailAuthError.accountActionFailed("Could not complete this account action. Please try again.")
        }
        return EmailAuthError.accountActionFailed(message)
    }

    private func validatedEmail(_ email: String) throws -> String {
        let clean = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = clean.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !clean.contains(where: \.isWhitespace) else { throw EmailAuthError.invalidEmail }
        return clean
    }

    func signOut() {
        guard !isBusy else { return }
        guard FirebaseApp.app() != nil else { return }
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
            user = nil
        } catch {
            self.error = accountErrorMessage(error)
        }
    }
}

@MainActor
private struct FirebaseEmailChangeClient: EmailChangeClient {
    var currentAccount: EmailChangeAccount? {
        guard let user = Auth.auth().currentUser, let email = user.email else { return nil }
        return .init(id: user.uid, email: email, hasPassword: user.providerData.isEmpty ||
            user.providerData.contains { $0.providerID == EmailAuthProviderID })
    }

    func reauthenticate(email: String, password: String) async throws {
        guard let user = Auth.auth().currentUser else { throw EmailChangeError.accountChanged }
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        _ = try await user.reauthenticate(with: credential)
    }

    func sendVerification(to email: String) async throws {
        guard let user = Auth.auth().currentUser else { throw EmailChangeError.accountChanged }
        try await user.sendEmailVerification(beforeUpdatingEmail: email)
    }

    func reloadAccount() async throws {
        guard let user = Auth.auth().currentUser else { throw EmailChangeError.accountChanged }
        try await user.reload()
    }
}
