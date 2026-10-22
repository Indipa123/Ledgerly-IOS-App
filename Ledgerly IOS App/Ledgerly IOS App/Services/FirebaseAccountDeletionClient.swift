import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import GoogleSignIn
import UIKit
import UserNotifications

enum AccountDeletionVerification: String, CaseIterable, Identifiable {
    case password = "Password", google = "Google"
    var id: Self { self }
}

@MainActor
final class FirebaseAccountDeletionClient: AccountDeletionClient {
    private let uid: String
    private let password: String
    private let method: AccountDeletionVerification
    private let store: LedgerStore
    private let trips: ShoppingTripStore
    private let progress: (String) -> Void
    var currentAccountID: String? { Auth.auth().currentUser?.uid }

    init(uid: String, password: String, method: AccountDeletionVerification,
         store: LedgerStore, trips: ShoppingTripStore, progress: @escaping (String) -> Void) {
        self.uid = uid
        self.password = password
        self.method = method
        self.store = store
        self.trips = trips
        self.progress = progress
    }

    private func account() throws -> FirebaseAuth.User {
        guard let user = Auth.auth().currentUser else { throw AccountDeletionError.notSignedIn }
        guard user.uid == uid else { throw AccountDeletionError.accountChanged }
        return user
    }

    func verifyIdentity() async throws {
        progress("Verifying your identity…")
        let user = try account()
        let credential: AuthCredential
        switch method {
        case .password:
            guard let email = user.email, !password.isEmpty,
                  user.providerData.contains(where: { $0.providerID == EmailAuthProviderID }) else {
                throw AccountDeletionError.notSignedIn
            }
            credential = EmailAuthProvider.credential(withEmail: email, password: password)
        case .google:
            guard let subject = user.providerData.first(where: { $0.providerID == GoogleAuthProviderID })?.uid,
                  let clientID = FirebaseApp.app()?.options.clientID,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }),
                  var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
                throw AccountDeletionError.notSignedIn
            }
            while let next = presenter.presentedViewController { presenter = next }
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard result.user.userID == subject, let token = result.user.idToken?.tokenString else {
                throw AccountDeletionError.accountChanged
            }
            _ = try account()
            credential = GoogleAuthProvider.credential(withIDToken: token,
                accessToken: result.user.accessToken.tokenString)
        }
        _ = try await user.reauthenticate(with: credential)
        _ = try account()
        _ = try await user.getIDToken(forcingRefresh: true)
        _ = try account()
    }

    func checkCloudSupport() async throws {
        _ = try account()
        do {
            _ = try await Firestore.firestore().collection("users").document(uid).getDocument(source: .server)
        } catch {
            let error = error as NSError
            if error.domain == FirestoreErrorDomain && error.code == 7 { throw AccountDeletionError.unavailable }
            throw error
        }
        _ = try account()
    }

    func freezeCloudWrites() async throws {
        progress("Protecting your account from new uploads…")
        store.suspendForAccountDeletion(uid)
        let root = Firestore.firestore().collection("users").document(uid)
        let snapshot = try await root.getDocument(source: .server)
        _ = try account()
        if !snapshot.exists {
            try await root.setData(["deletionRequestedAt": FieldValue.serverTimestamp()])
        } else if snapshot.data()?["deletionRequestedAt"] == nil {
            throw AccountDeletionError.unavailable
        }
        _ = try account()
        // Fail closed if deployed rules do not reject writes after the marker.
        for collection in ["transactions", "budgets"] {
            let probe = root.collection(collection).document("_deletion-protection-check")
            do {
                try await probe.setData(["deletionProbe": true])
            } catch {
                let error = error as NSError
                if error.domain == FirestoreErrorDomain && error.code == 7 { continue }
                throw error
            }
            try await probe.delete()
            throw AccountDeletionError.unavailable
        }
        _ = try account()
    }

    func deleteCloudData() async throws {
        progress("Removing cloud transactions and budgets…")
        let database = Firestore.firestore()
        for collection in ["transactions", "budgets"] {
            let reference = database.collection("users").document(uid).collection(collection)
            while true {
                _ = try account()
                let page = try await reference.limit(to: 200).getDocuments(source: .server)
                _ = try account()
                guard !page.documents.isEmpty else { break }
                let batch = database.batch()
                for document in page.documents { batch.deleteDocument(document.reference) }
                try await batch.commit()
                _ = try account()
            }
        }
    }

    func deleteLocalData() async throws {
        progress("Clearing this device's account data…")
        _ = try account()
        await store.personalLearning.stopAndWait()
        _ = try account()
        guard let pending = try AccountDeletionJournal.shared.load(uid) else {
            throw AccountDeletionError.invalidRecoveryRecord
        }
        let clearClaimedGuest = pending.shouldClearClaimedGuest
        try store.eraseLocalAccount(uid, includesClaimedGuest: clearClaimedGuest)
        try trips.eraseForAccountDeletion(uid, includesClaimedGuest: clearClaimedGuest)
        PlaceArrivalMonitor.shared.suspendForAccountDeletion(uid)
        try BudgetWidgetPublisher.clear()
        let owners = clearClaimedGuest ? [uid, "guest"] : [uid]
        let center = UNUserNotificationCenter.current()
        let notifications = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        _ = try account()
        func owned(_ request: UNNotificationRequest) -> Bool {
            owners.contains { owner in
                ["reminder.", "place.", "departure.", "placeTest.", BudgetAlertType.monthly.requestPrefix,
                 BudgetAlertType.category.requestPrefix].contains { request.identifier.hasPrefix($0 + owner + ".") }
            }
        }
        center.removePendingNotificationRequests(withIdentifiers: notifications.filter(owned).map(\.identifier))
        center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request).filter(owned).map(\.identifier))
        let defaults = UserDefaults.standard
        let prefixes = owners.flatMap { owner in ["ledgerly.monitor.\(owner).", "ledgerly.budgetAlert.\(owner).",
            "ledgerly.categoryBudgetAlert.\(owner)."] }
        let keys = owners.flatMap { ["ledgerly.pendingEmailChange.\($0)", "ledgerly.categoryLearning.excluded.\($0)"] }
        for key in defaults.dictionaryRepresentation().keys where keys.contains(key) || prefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
        if owners.contains(defaults.string(forKey: "ledgerly.monitor.lastOwner") ?? "") {
            defaults.removeObject(forKey: "ledgerly.monitor.lastOwner")
        }
        // Keep the guest-claim marker: a deleted account's former guest data must never be reimported.
        let database = Firestore.firestore()
        try await database.terminate()
        try await database.clearPersistence()
        _ = try account()
    }

    func deleteLogin() async throws {
        progress("Removing your Ledgerly sign-in…")
        try await account().delete()
    }
}
