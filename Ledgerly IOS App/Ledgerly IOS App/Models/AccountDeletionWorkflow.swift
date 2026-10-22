import Foundation

extension Notification.Name {
    static let ledgerlyAccountDeletionChanged = Notification.Name("ledgerly.accountDeletionChanged")
}

struct PendingAccountDeletion: Codable, Equatable, Identifiable {
    enum Phase: String, Codable { case requested, cloudRemoved, localRemoved }
    var id: String { accountID }
    let accountID: String
    let requestedAt: Date
    let includesClaimedGuest: Bool
    var receiptIDs: Set<UUID> = []
    var phase: Phase = .requested
    var shouldClearClaimedGuest: Bool { includesClaimedGuest && phase != .localRemoved }
}

/// Atomic, backup-excluded recovery records contain identifiers only, never credentials.
struct AccountDeletionJournal {
    static let shared = AccountDeletionJournal()
    let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountDeletion", isDirectory: true)
    }

    func contains(_ uid: String) -> Bool { FileManager.default.fileExists(atPath: url(uid).path) }

    func blocks(owner: String?) -> Bool {
        if let owner, owner != "guest" { return contains(owner) }
        guard let claimed = UserDefaults.standard.string(forKey: "ledgerly.guestClaimedBy"), contains(claimed) else { return false }
        return (try? load(claimed))?.phase != .localRemoved
    }

    func load(_ uid: String) throws -> PendingAccountDeletion? {
        guard contains(uid) else { return nil }
        let record = try JSONDecoder().decode(PendingAccountDeletion.self, from: Data(contentsOf: url(uid)))
        guard record.accountID == uid else { throw AccountDeletionError.invalidRecoveryRecord }
        return record
    }

    func firstPending() throws -> PendingAccountDeletion? {
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(PendingAccountDeletion.self, from: Data(contentsOf: $0)) }
            .sorted { $0.requestedAt < $1.requestedAt }.first
    }

    func save(_ record: PendingAccountDeletion) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = url(record.accountID)
        try JSONEncoder().encode(record).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try destination.setResourceValues(values)
        NotificationCenter.default.post(name: .ledgerlyAccountDeletionChanged, object: nil)
    }

    func remove(_ uid: String) throws {
        if contains(uid) { try FileManager.default.removeItem(at: url(uid)) }
        NotificationCenter.default.post(name: .ledgerlyAccountDeletionChanged, object: nil)
    }

    private func url(_ uid: String) -> URL {
        let key = Data(uid.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return folder.appendingPathComponent(key).appendingPathExtension("json")
    }
}

enum AccountDeletionError: LocalizedError {
    case accountChanged, notSignedIn, invalidRecoveryRecord, unavailable, busy
    var errorDescription: String? {
        switch self {
        case .accountChanged: "The signed-in account changed. Sign in to the account shown on this deletion request."
        case .notSignedIn: "Sign in to the same account to retry. Its deletion has not been confirmed."
        case .invalidRecoveryRecord: "The deletion recovery record could not be opened. Keep this device's data and contact support."
        case .unavailable: "We couldn't complete deletion safely. Keep Ledgerly installed and try again later."
        case .busy: "An account deletion is already in progress."
        }
    }
}

@MainActor
protocol AccountDeletionClient {
    var currentAccountID: String? { get }
    func verifyIdentity() async throws
    func checkCloudSupport() async throws
    func freezeCloudWrites() async throws
    func deleteCloudData() async throws
    func deleteLocalData() async throws
    func deleteLogin() async throws
}

@MainActor
enum AccountDeletionWorkflow {
    static func run(_ request: PendingAccountDeletion, journal suppliedJournal: AccountDeletionJournal? = nil,
                    client: any AccountDeletionClient) async throws {
        let journal = suppliedJournal ?? .shared
        func checkAccount() throws {
            guard client.currentAccountID == request.accountID else { throw AccountDeletionError.accountChanged }
        }
        try checkAccount()
        try await client.verifyIdentity()
        try checkAccount()
        try await client.checkCloudSupport()
        try checkAccount()
        // Confirmation and verification precede the durable request and any destructive work.
        var pending = try journal.load(request.accountID) ?? request
        try journal.save(pending)
        try await client.freezeCloudWrites()
        try checkAccount()
        // Repeating cleanup is intentional: interrupted batches and acknowledgements are safe to retry.
        try await client.deleteCloudData()
        try checkAccount()
        // Keep the completed local-cleanup checkpoint when retrying a failed login deletion.
        if pending.phase != .localRemoved { pending.phase = .cloudRemoved }
        try journal.save(pending)
        try await client.deleteLocalData()
        try checkAccount()
        pending = try journal.load(request.accountID) ?? pending
        pending.phase = .localRemoved
        try journal.save(pending)
        // Delete authentication last so failed cleanup never loses its owner credentials.
        try await client.deleteLogin()
        try journal.remove(request.accountID)
    }
}
