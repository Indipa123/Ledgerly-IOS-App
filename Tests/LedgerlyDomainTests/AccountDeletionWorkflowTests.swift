import Foundation
import Testing
@testable import LedgerlyDomain

@MainActor
struct AccountDeletionWorkflowTests {
    private final class Client: AccountDeletionClient {
        var currentAccountID: String? = "owner"
        var calls: [String] = []
        var failing: String?
        var switchAt: String?
        var localAction: (() throws -> Void)?
        func step(_ name: String) throws {
            calls.append(name)
            if switchAt == name { currentAccountID = "different-account" }
            if failing == name { throw Failure.expected }
        }
        func verifyIdentity() async throws { try step("verify") }
        func checkCloudSupport() async throws { try step("support") }
        func freezeCloudWrites() async throws { try step("fence") }
        func deleteCloudData() async throws { try step("cloud") }
        func deleteLocalData() async throws { try step("local"); try localAction?() }
        func deleteLogin() async throws { try step("login"); currentAccountID = nil }
    }
    private enum Failure: Error { case expected }
    private let request = PendingAccountDeletion(accountID: "owner", requestedAt: .now, includesClaimedGuest: true)

    private func journal() -> AccountDeletionJournal {
        .init(folder: FileManager.default.temporaryDirectory.appendingPathComponent("ledgerly-deletion-tests-\(UUID())"))
    }

    @Test func deletesLoginOnlyAfterConfirmedCloudAndLocalCleanup() async throws {
        let journal = journal()
        defer { try? FileManager.default.removeItem(at: journal.folder) }
        let client = Client()
        try await AccountDeletionWorkflow.run(request, journal: journal, client: client)
        #expect(client.calls == ["verify", "support", "fence", "cloud", "local", "login"])
        #expect(!journal.contains("owner"))
    }

    @Test(arguments: ["verify", "support"])
    func verificationOrMissingRulesNeverStartsDeletion(failing: String) async throws {
        let journal = journal()
        defer { try? FileManager.default.removeItem(at: journal.folder) }
        let client = Client()
        client.failing = failing
        await #expect(throws: Failure.self) { try await AccountDeletionWorkflow.run(request, journal: journal, client: client) }
        #expect(!journal.contains("owner"))
        #expect(!client.calls.contains("fence"))
        #expect(!client.calls.contains("login"))
    }

    @Test(arguments: ["fence", "cloud", "local", "login"])
    func interruptionRetainsRecoveryAndRetryRepeatsCleanup(failing: String) async throws {
        let journal = journal()
        defer { try? FileManager.default.removeItem(at: journal.folder) }
        let client = Client()
        client.failing = failing
        await #expect(throws: Failure.self) { try await AccountDeletionWorkflow.run(request, journal: journal, client: client) }
        let pending = try #require(try journal.load("owner"))
        #expect(pending.phase == (failing == "login" ? .localRemoved : failing == "local" ? .cloudRemoved : .requested))
        if failing != "login" { #expect(!client.calls.contains("login")) }
        client.failing = nil
        client.calls = []
        try await AccountDeletionWorkflow.run(pending, journal: journal, client: client)
        #expect(client.calls == ["verify", "support", "fence", "cloud", "local", "login"])
        #expect(!journal.contains("owner"))
    }

    @Test(arguments: ["verify", "cloud"])
    func switchingAccountsCannotDeleteTheOtherLogin(at step: String) async throws {
        let journal = journal()
        defer { try? FileManager.default.removeItem(at: journal.folder) }
        let client = Client()
        client.switchAt = step
        await #expect(throws: AccountDeletionError.self) {
            try await AccountDeletionWorkflow.run(request, journal: journal, client: client)
        }
        #expect(!client.calls.contains("local"))
        #expect(!client.calls.contains("login"))
        #expect(!journal.contains("different-account"))
    }

    @Test func receiptRecoverySurvivesPhaseUpdatesAndOtherRequestsAreKept() async throws {
        let journal = journal()
        defer { try? FileManager.default.removeItem(at: journal.folder) }
        let receiptID = UUID()
        try journal.save(.init(accountID: "other", requestedAt: .now, includesClaimedGuest: false))
        let client = Client()
        client.failing = "login"
        client.localAction = {
            var request = try #require(try journal.load("owner"))
            request.receiptIDs.insert(receiptID)
            try journal.save(request)
        }
        await #expect(throws: Failure.self) { try await AccountDeletionWorkflow.run(request, journal: journal, client: client) }
        #expect(try journal.load("owner")?.receiptIDs == [receiptID])
        #expect(journal.contains("other"))
        #expect(try journal.load("owner")?.phase == .localRemoved)
    }

    @Test func localErasureIncludesDeletedRecordsAndKeepsAnotherRepository() throws {
        let own = CoreDataLedgerRepository(inMemory: true)
        let other = CoreDataLedgerRepository(inMemory: true)
        let category = try #require(own.fetchCategories().first { $0.kind == .expense })
        let entry = LedgerEntry(id: UUID(), kind: .expense, amount: 300, title: "Test", category: category.name,
            date: .now, note: "", categoryID: category.id)
        try own.upsert(entry)
        try own.softDelete(id: entry.id)
        try own.setCurrentBudget(1_000)
        try own.savePlace(.init(id: UUID(), name: "Test place", latitude: 7, longitude: 80))
        let otherCategoryCount = try other.fetchCategories().count
        #expect(try own.receiptIDsForAccountDeletion() == [entry.id])
        try own.eraseForAccountDeletion()
        #expect(try own.receiptIDsForAccountDeletion().isEmpty)
        #expect(try own.fetchEntries().isEmpty)
        #expect(try own.fetchCategories().isEmpty)
        #expect(try own.fetchPlaces().isEmpty)
        #expect(try own.fetchCurrentBudget() == 0)
        #expect(try other.fetchCategories().count == otherCategoryCount)
    }

    @Test func retryAfterLocalCleanupKeepsNewGuestData() async throws {
        let journal = journal()
        defer { try? FileManager.default.removeItem(at: journal.folder) }
        let guest = CoreDataLedgerRepository(inMemory: true)
        try guest.setCurrentBudget(500)
        let client = Client()
        client.failing = "login"
        client.localAction = {
            let pending = try #require(try journal.load("owner"))
            if pending.shouldClearClaimedGuest { try guest.eraseForAccountDeletion() }
        }
        await #expect(throws: Failure.self) { try await AccountDeletionWorkflow.run(request, journal: journal, client: client) }
        #expect(try guest.fetchCurrentBudget() == 0)
        try guest.setCurrentBudget(1_234)
        let pending = try #require(try journal.load("owner"))
        client.failing = nil
        try await AccountDeletionWorkflow.run(pending, journal: journal, client: client)
        #expect(try guest.fetchCurrentBudget() == 1_234)
    }
}
