import Foundation
import Testing
@testable import LedgerlyDomain

@MainActor
struct EmailChangeWorkflowTests {
    private let account = EmailChangeAccount(id: "account-a", email: "old@example.com", hasPassword: true)

    @Test func verifiesIdentityBeforeRequestingTheNewAddress() async throws {
        let client = EmailChangeStub(account: account)
        let pending = try await EmailChangeWorkflow.request(newEmail: " new@example.com ",
            confirmation: "NEW@example.com", password: "fixture-password",
            expectedAccountID: account.id, client: client)
        #expect(client.calls == ["reauthenticate:old@example.com", "send:new@example.com"])
        #expect(client.currentAccount == account) // Sending a link does not change the address.
        #expect(pending.newEmail == "new@example.com")
        let data = try JSONEncoder().encode(pending)
        #expect(try JSONDecoder().decode(PendingEmailChange.self, from: data) == pending)
        #expect(!String(decoding: data, as: UTF8.self).contains("fixture-password"))
    }

    @Test func wrongPasswordNeverSendsAVerificationEmail() async {
        let client = EmailChangeStub(account: account)
        client.reauthenticationError = .rejected
        await #expect(throws: EmailChangeStub.Failure.rejected) {
            try await EmailChangeWorkflow.request(newEmail: "new@example.com", confirmation: "new@example.com",
                password: "wrong", expectedAccountID: account.id, client: client)
        }
        #expect(client.calls == ["reauthenticate:old@example.com"])
    }

    @Test func addressCaseNormalisationDoesNotLookLikeAnAccountSwitch() async throws {
        let client = EmailChangeStub(account: account)
        client.afterReauthentication = {
            client.currentAccount = .init(id: account.id, email: "OLD@example.com", hasPassword: true)
        }
        let pending = try await EmailChangeWorkflow.request(newEmail: "new@example.com",
            confirmation: "new@example.com", password: "fixture-password",
            expectedAccountID: account.id, client: client)
        #expect(pending.newEmail == "new@example.com")
        #expect(client.calls.last == "send:new@example.com")
    }

    @Test func switchingAccountsDuringReauthenticationPreventsTheRequest() async {
        let client = EmailChangeStub(account: account)
        client.afterReauthentication = {
            client.currentAccount = .init(id: "account-b", email: "other@example.com", hasPassword: true)
        }
        await #expect(throws: EmailChangeError.accountChanged) {
            try await EmailChangeWorkflow.request(newEmail: "new@example.com", confirmation: "new@example.com",
                password: "fixture-password", expectedAccountID: account.id, client: client)
        }
        #expect(client.calls == ["reauthenticate:old@example.com"])
    }

    @Test func rejectsInvalidUnchangedAndMismatchedAddressesBeforeNetworkWork() async {
        let client = EmailChangeStub(account: account)
        for (email, confirmation, failure) in [
            ("invalid", "invalid", EmailChangeError.invalidEmail),
            ("OLD@example.com", "OLD@example.com", .unchanged),
            ("new@example.com", "typo@example.com", .confirmationMismatch)
        ] {
            await #expect(throws: failure) {
                try await EmailChangeWorkflow.request(newEmail: email, confirmation: confirmation,
                    password: "fixture-password", expectedAccountID: account.id, client: client)
            }
        }
        #expect(client.calls.isEmpty)
    }

    @Test func googleOnlyAndStaleAccountFormsCannotSendRequests() async {
        let client = EmailChangeStub(account: .init(id: account.id, email: account.email, hasPassword: false))
        await #expect(throws: EmailChangeError.providerManaged) {
            try await EmailChangeWorkflow.request(newEmail: "new@example.com", confirmation: "new@example.com",
                password: "fixture-password", expectedAccountID: account.id, client: client)
        }
        await #expect(throws: EmailChangeError.accountChanged) {
            try await EmailChangeWorkflow.request(newEmail: "new@example.com", confirmation: "new@example.com",
                password: "fixture-password", expectedAccountID: "different-account", client: client)
        }
        #expect(client.calls.isEmpty)
    }

    @Test func reportsSuccessOnlyAfterTheServerReturnsTheVerifiedAddress() async throws {
        let client = EmailChangeStub(account: account)
        let pending = PendingEmailChange(newEmail: "new@example.com", requestedAt: .now)
        #expect(try await !EmailChangeWorkflow.check(pending, expectedAccountID: account.id, client: client))
        client.afterReload = {
            client.currentAccount = .init(id: account.id, email: "new@example.com", hasPassword: true)
        }
        #expect(try await EmailChangeWorkflow.check(pending, expectedAccountID: account.id, client: client))
        #expect(client.calls == ["reload", "reload"])
    }

    @Test func cannotConfirmAnotherAccountsEmailAfterReload() async {
        let client = EmailChangeStub(account: account)
        client.afterReload = {
            client.currentAccount = .init(id: "account-b", email: "new@example.com", hasPassword: true)
        }
        await #expect(throws: EmailChangeError.accountChanged) {
            try await EmailChangeWorkflow.check(.init(newEmail: "new@example.com", requestedAt: .now),
                expectedAccountID: account.id, client: client)
        }
    }
}

@MainActor
private final class EmailChangeStub: EmailChangeClient {
    enum Failure: Error { case rejected }
    var currentAccount: EmailChangeAccount?
    var calls: [String] = []
    var reauthenticationError: Failure?
    var afterReauthentication: (() -> Void)?
    var afterReload: (() -> Void)?

    init(account: EmailChangeAccount) { currentAccount = account }

    func reauthenticate(email: String, password: String) async throws {
        calls.append("reauthenticate:\(email)")
        if let reauthenticationError { throw reauthenticationError }
        afterReauthentication?()
    }

    func sendVerification(to email: String) async throws { calls.append("send:\(email)") }
    func reloadAccount() async throws {
        calls.append("reload")
        afterReload?()
    }
}
