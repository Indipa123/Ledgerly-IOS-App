import Foundation
import FirebaseFirestore

@MainActor
final class CloudLedgerSync {
    private let database = Firestore.firestore()
    private var entryListener: ListenerRegistration?
    private var budgetListener: ListenerRegistration?
    private(set) var userID: String?
    var onEntry: ((CloudEntry) -> Void)?
    var onBudget: ((CloudBudget) -> Void)?
    var onError: ((String) -> Void)?

    func start(userID: String) {
        stop()
        self.userID = userID
        let root = database.collection("users").document(userID)
        entryListener = root.collection("transactions").addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self, self.userID == userID else { return }
                if let error { self.onError?(error.localizedDescription); return }
                for change in snapshot?.documentChanges ?? [] {
                    if let entry = Self.decodeEntry(change.document) { self.onEntry?(entry) }
                }
            }
        }
        budgetListener = root.collection("budgets").addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self, self.userID == userID else { return }
                if let error { self.onError?(error.localizedDescription); return }
                for change in snapshot?.documentChanges ?? [] {
                    if let budget = Self.decodeBudget(change.document) { self.onBudget?(budget) }
                }
            }
        }
    }

    func stop() {
        entryListener?.remove()
        budgetListener?.remove()
        entryListener = nil
        budgetListener = nil
        userID = nil
    }

    func upload(_ entry: CloudEntry) {
        guard let userID else { return }
        database.collection("users").document(userID).collection("transactions")
            .document(entry.id.uuidString).setData(Self.entryData(entry)) { [weak self] error in
                if let error { Task { @MainActor in self?.onError?(error.localizedDescription) } }
            }
    }

    func uploadInitial(_ entry: CloudEntry) async throws {
        guard let userID else { return }
        let ref = database.collection("users").document(userID).collection("transactions")
            .document(entry.id.uuidString)
        let remote = try await ref.getDocument(source: .server)
        if let existing = Self.decodeEntry(remote), existing.updatedAt >= entry.updatedAt { return }
        try await ref.setData(Self.entryData(entry))
    }

    func upload(_ budget: CloudBudget) {
        guard let userID else { return }
        database.collection("users").document(userID).collection("budgets")
            .document(Self.monthID(budget.month)).setData(Self.budgetData(budget)) { [weak self] error in
                if let error { Task { @MainActor in self?.onError?(error.localizedDescription) } }
            }
    }

    func uploadInitialBudget(_ budget: CloudBudget) async throws {
        guard let userID else { return }
        let ref = database.collection("users").document(userID).collection("budgets")
            .document(Self.monthID(budget.month))
        let remote = try await ref.getDocument(source: .server)
        if let existing = Self.decodeBudget(remote), existing.updatedAt >= budget.updatedAt { return }
        try await ref.setData(Self.budgetData(budget))
    }

    private static func entryData(_ entry: CloudEntry) -> [String: Any] {
        ["kind": Int(entry.kind.rawValue), "amount": NSDecimalNumber(decimal: entry.amount).stringValue,
         "title": entry.title, "category": entry.category, "date": Timestamp(date: entry.date),
         "note": entry.note, "createdAt": Timestamp(date: entry.createdAt),
         "updatedAt": Timestamp(date: entry.updatedAt),
         "deletedAt": entry.deletedAt.map { Timestamp(date: $0) } ?? NSNull()]
    }

    private static func budgetData(_ budget: CloudBudget) -> [String: Any] {
        ["month": Timestamp(date: budget.month),
         "amount": NSDecimalNumber(decimal: budget.amount).stringValue,
         "updatedAt": Timestamp(date: budget.updatedAt)]
    }

    private static func monthID(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private static func decodeEntry(_ snapshot: DocumentSnapshot) -> CloudEntry? {
        guard let data = snapshot.data(), let id = UUID(uuidString: snapshot.documentID),
              let kindNumber = data["kind"] as? Int,
              let kind = EntryKind(rawValue: Int16(kindNumber)),
              let amountText = data["amount"] as? String,
              let amount = Decimal(string: amountText),
              let title = data["title"] as? String,
              let category = data["category"] as? String,
              let date = (data["date"] as? Timestamp)?.dateValue(),
              let note = data["note"] as? String,
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
              let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else { return nil }
        return CloudEntry(id: id, kind: kind, amount: amount, title: title, category: category,
                          date: date, note: note, createdAt: createdAt, updatedAt: updatedAt,
                          deletedAt: (data["deletedAt"] as? Timestamp)?.dateValue())
    }

    private static func decodeBudget(_ snapshot: DocumentSnapshot) -> CloudBudget? {
        guard let data = snapshot.data(),
              let month = (data["month"] as? Timestamp)?.dateValue(),
              let amountText = data["amount"] as? String,
              let amount = Decimal(string: amountText),
              let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else { return nil }
        return CloudBudget(month: month, amount: amount, updatedAt: updatedAt)
    }
}
