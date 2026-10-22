import Foundation

struct PendingEmailChange: Codable, Equatable {
    let newEmail: String
    let requestedAt: Date
}

struct EmailChangeAccount: Equatable {
    let id: String
    let email: String
    let hasPassword: Bool
}

enum EmailChangeError: LocalizedError, Equatable {
    case accountChanged
    case providerManaged
    case invalidEmail
    case unchanged
    case confirmationMismatch
    case missingPassword

    var errorDescription: String? {
        switch self {
        case .accountChanged: "Your signed-in account changed. Open this screen again to continue."
        case .providerManaged: "Manage this account's email address through its sign-in provider."
        case .invalidEmail: "Enter a valid new email address."
        case .unchanged: "Choose an email address different from your current address."
        case .confirmationMismatch: "The new email addresses do not match."
        case .missingPassword: "Enter your current password to confirm this change."
        }
    }
}

@MainActor
protocol EmailChangeClient {
    var currentAccount: EmailChangeAccount? { get }
    func reauthenticate(email: String, password: String) async throws
    func sendVerification(to email: String) async throws
    func reloadAccount() async throws
}

@MainActor
enum EmailChangeWorkflow {
    static func request(newEmail: String, confirmation: String, password: String,
                        expectedAccountID: String, client: any EmailChangeClient) async throws -> PendingEmailChange {
        guard let account = client.currentAccount, account.id == expectedAccountID else {
            throw EmailChangeError.accountChanged
        }
        guard account.hasPassword else { throw EmailChangeError.providerManaged }
        let email = try validatedAddress(newEmail)
        guard matches(email, account.email) == false else { throw EmailChangeError.unchanged }
        guard matches(email, confirmation.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw EmailChangeError.confirmationMismatch
        }
        guard !password.isEmpty else { throw EmailChangeError.missingPassword }
        try await client.reauthenticate(email: account.email, password: password)
        // Reauthentication is asynchronous. Never send a request for a newly selected account.
        guard let verified = client.currentAccount, verified.id == account.id, verified.hasPassword,
              matches(verified.email, account.email) else { throw EmailChangeError.accountChanged }
        try await client.sendVerification(to: email)
        guard client.currentAccount?.id == account.id else { throw EmailChangeError.accountChanged }
        return PendingEmailChange(newEmail: email, requestedAt: .now)
    }

    static func check(_ pending: PendingEmailChange, expectedAccountID: String,
                      client: any EmailChangeClient) async throws -> Bool {
        guard client.currentAccount?.id == expectedAccountID else { throw EmailChangeError.accountChanged }
        try await client.reloadAccount()
        guard let refreshed = client.currentAccount, refreshed.id == expectedAccountID else {
            throw EmailChangeError.accountChanged
        }
        return matches(refreshed.email, pending.newEmail)
    }

    static func matches(_ first: String, _ second: String) -> Bool {
        first.compare(second, options: [.caseInsensitive]) == .orderedSame
    }

    private static func validatedAddress(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = clean.split(separator: "@", omittingEmptySubsequences: false)
        guard clean.count <= 254, parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !clean.contains(where: \.isWhitespace) else { throw EmailChangeError.invalidEmail }
        return clean
    }
}
