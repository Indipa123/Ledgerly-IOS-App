import Combine
import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import UIKit

@MainActor
final class AuthSession: ObservableObject {
    @Published private(set) var user: FirebaseAuth.User?
    @Published private(set) var isBusy = false
    @Published var error: String?

    private var listener: AuthStateDidChangeListenerHandle?

    func start() {
        guard listener == nil, FirebaseApp.app() != nil else { return }
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.user = user }
        }
    }

    func signInWithGoogle(onSuccess: @escaping () -> Void = {}) {
        guard !isBusy else { return }
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            error = "Google sign-in is not configured for this build."
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
                if let signInError {
                    self.error = signInError.localizedDescription
                    return
                }
                guard let googleUser = result?.user,
                      let idToken = googleUser.idToken?.tokenString else {
                    self.error = "Google did not return a sign-in token."
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
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func signOut() {
        guard FirebaseApp.app() != nil else { return }
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
            user = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
