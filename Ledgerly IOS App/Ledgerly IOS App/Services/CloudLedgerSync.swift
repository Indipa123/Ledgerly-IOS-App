import Foundation
import FirebaseFirestore

@MainActor
final class CloudLedgerSync {
    private struct CollectionState {
        let pendingWrites: Int
        let fromCache: Bool
    }

    private var database: Firestore { Firestore.firestore() }
    private var deletionListener: ListenerRegistration?
    private var entryListener: ListenerRegistration?
    private var budgetListener: ListenerRegistration?
    private var entryState: CollectionState?
    private var budgetState: CollectionState?
    private var listenerGeneration = 0
    private(set) var userID: String?
    var onLibraryRecords: (([CloudLibraryRecord]) -> Void)?
    var onDeletionRequested: (() -> Void)?
    var onEntry: ((CloudEntry) -> Void)?
    var onBudget: ((CloudBudget) -> Void)?
    var onCategoryBudget: ((CategoryBudget) -> Void)?
    var onLifeEvent: ((LifeEvent) -> Void)?
    var onFriend: ((LedgerFriend) -> Void)?
    var onSplitBill: ((SplitBill) -> Void)?
    var onError: ((String) -> Void)?
    var onWriteError: ((String) -> Void)?
    var onStatus: ((_ pendingWrites: Int, _ fromCache: Bool) -> Void)?

    func start(userID: String) {
        stop()
        guard !AccountDeletionJournal.shared.contains(userID) else { return }
        let generation = listenerGeneration
        self.userID = userID
        let root = database.collection("users").document(userID)
        deletionListener = root.addSnapshotListener { [weak self] snapshot, _ in
            guard snapshot?.data()?["deletionRequestedAt"] != nil else { return }
            Task { @MainActor in
                guard let self, self.userID == userID, self.listenerGeneration == generation else { return }
                self.onDeletionRequested?()
                self.stop()
            }
        }
        entryListener = root.collection("transactions").addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self, self.userID == userID,
                      self.listenerGeneration == generation else { return }
                if let error { self.onError?(error.localizedDescription); return }
                guard let snapshot else { return }
                self.entryState = CollectionState(
                    pendingWrites: snapshot.documents.filter { $0.metadata.hasPendingWrites }.count,
                    fromCache: snapshot.metadata.isFromCache
                )
                self.publishStatus()
                for change in snapshot.documentChanges {
                    if let entry = Self.decodeEntry(change.document) { self.onEntry?(entry) }
                }
            }
        }
        budgetListener = root.collection("budgets").addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self, self.userID == userID,
                      self.listenerGeneration == generation else { return }
                if let error { self.onError?(error.localizedDescription); return }
                guard let snapshot else { return }
                do { self.onLibraryRecords?(try Self.libraryRecords(snapshot.documents)) }
                catch { self.onError?("Could not restore synced attachments: \(error.localizedDescription)") }
                self.budgetState = CollectionState(
                    pendingWrites: snapshot.documents.filter { $0.metadata.hasPendingWrites }.count,
                    fromCache: snapshot.metadata.isFromCache
                )
                self.publishStatus()
                for change in snapshot.documentChanges {
                    if change.document.documentID.hasPrefix("library") { continue }
                    if change.document.documentID.hasPrefix("friend-") {
                        if let friend = Self.decodeFriend(change.document) { self.onFriend?(friend) }
                    } else if change.document.documentID.hasPrefix("split-") {
                        if let bill = Self.decodeSplitBill(change.document) { self.onSplitBill?(bill) }
                    } else if change.document.documentID.hasPrefix("event-") {
                        if let event = Self.decodeLifeEvent(change.document) {
                            self.onLifeEvent?(event)
                        }
                    } else if change.document.data()["categoryName"] != nil {
                        if let budget = Self.decodeCategoryBudget(change.document) {
                            self.onCategoryBudget?(budget)
                        }
                    } else if let budget = Self.decodeBudget(change.document) {
                        self.onBudget?(budget)
                    }
                }
            }
        }
    }

    func stop() {
        listenerGeneration += 1
        deletionListener?.remove()
        deletionListener = nil
        entryListener?.remove()
        budgetListener?.remove()
        entryListener = nil
        budgetListener = nil
        entryState = nil
        budgetState = nil
        userID = nil
    }

    private func publishStatus() {
        guard let entryState, let budgetState else { return }
        onStatus?(entryState.pendingWrites + budgetState.pendingWrites,
                  entryState.fromCache || budgetState.fromCache)
    }

    func upload(_ entry: CloudEntry) {
        guard let userID, !AccountDeletionJournal.shared.contains(userID) else { return }
        database.collection("users").document(userID).collection("transactions")
            .document(entry.id.uuidString).setData(Self.entryData(entry)) { [weak self] error in
                guard let error else { return }
                let message = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.userID == userID else { return }
                    self.onWriteError?(message)
                }
            }
    }

    func uploadInitial(_ entry: CloudEntry) async throws {
        guard let userID, !AccountDeletionJournal.shared.contains(userID) else { return }
        let ref = database.collection("users").document(userID).collection("transactions")
            .document(entry.id.uuidString)
        let remote = try await ref.getDocument(source: .server)
        guard self.userID == userID, !AccountDeletionJournal.shared.contains(userID) else { throw CancellationError() }
        if let existing = Self.decodeEntry(remote), existing.updatedAt >= entry.updatedAt { return }
        try await ref.setData(Self.entryData(entry))
    }

    func upload(_ budget: CloudBudget) {
        guard let userID, !AccountDeletionJournal.shared.contains(userID) else { return }
        database.collection("users").document(userID).collection("budgets")
            .document(Self.monthID(budget.month)).setData(Self.budgetData(budget)) { [weak self] error in
                guard let error else { return }
                let message = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.userID == userID else { return }
                    self.onWriteError?(message)
                }
            }
    }

    func uploadInitialBudget(_ budget: CloudBudget) async throws {
        guard let userID, !AccountDeletionJournal.shared.contains(userID) else { return }
        let ref = database.collection("users").document(userID).collection("budgets")
            .document(Self.monthID(budget.month))
        let remote = try await ref.getDocument(source: .server)
        guard self.userID == userID, !AccountDeletionJournal.shared.contains(userID) else { throw CancellationError() }
        if let existing = Self.decodeBudget(remote), existing.updatedAt >= budget.updatedAt { return }
        try await ref.setData(Self.budgetData(budget))
    }

    func upload(_ budget: CategoryBudget) {
        guard let userID, !AccountDeletionJournal.shared.contains(userID) else { return }
        database.collection("users").document(userID).collection("budgets")
            .document(budget.id).setData(Self.categoryBudgetData(budget)) { [weak self] error in
                guard let error else { return }
                let message = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.userID == userID else { return }
                    self.onWriteError?(message)
                }
            }
    }

    func uploadInitial(_ budget: CategoryBudget) async throws {
        guard let userID, !AccountDeletionJournal.shared.contains(userID) else { return }
        let ref = database.collection("users").document(userID).collection("budgets")
            .document(budget.id)
        let remote = try await ref.getDocument(source: .server)
        guard self.userID == userID, !AccountDeletionJournal.shared.contains(userID) else { throw CancellationError() }
        if let existing = Self.decodeCategoryBudget(remote), existing.updatedAt >= budget.updatedAt { return }
        try await ref.setData(Self.categoryBudgetData(budget))
    }

    func upload(_ event: LifeEvent) {
        guard let userID, !AccountDeletionJournal.shared.contains(userID) else { return }
        database.collection("users").document(userID).collection("budgets")
            .document("event-\(event.id.uuidString)").setData(Self.lifeEventData(event)) { [weak self] error in
                guard let error else { return }
                let message = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.userID == userID else { return }
                    self.onWriteError?(message)
                }
            }
    }

    func uploadInitial(_ event: LifeEvent) async throws {
        guard let userID, !AccountDeletionJournal.shared.contains(userID) else { return }
        let ref = database.collection("users").document(userID).collection("budgets")
            .document("event-\(event.id.uuidString)")
        let remote = try await ref.getDocument(source: .server)
        guard self.userID == userID, !AccountDeletionJournal.shared.contains(userID) else { throw CancellationError() }
        if let existing = Self.decodeLifeEvent(remote), existing.updatedAt >= event.updatedAt { return }
        try await ref.setData(Self.lifeEventData(event))
    }

    func upload(_ friend: LedgerFriend) {
        guard let userID, !AccountDeletionJournal.shared.contains(userID) else { return }
        database.collection("users").document(userID).collection("budgets")
            .document("friend-\(friend.id.uuidString)").setData(Self.friendData(friend)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.userID == userID else { return }
                    self.onWriteError?(error.localizedDescription)
                }
            }
    }

    func uploadInitial(_ friend: LedgerFriend) async throws {
        guard let userID, !AccountDeletionJournal.shared.contains(userID) else { return }
        let ref = database.collection("users").document(userID).collection("budgets")
            .document("friend-\(friend.id.uuidString)")
        let remote = try await ref.getDocument(source: .server)
        guard self.userID == userID, !AccountDeletionJournal.shared.contains(userID) else { throw CancellationError() }
        if let existing = Self.decodeFriend(remote), existing.updatedAt >= friend.updatedAt { return }
        try await ref.setData(Self.friendData(friend))
    }

    func upload(_ bill: SplitBill) {
        guard let userID, !AccountDeletionJournal.shared.contains(userID) else { return }
        database.collection("users").document(userID).collection("budgets")
            .document("split-\(bill.id.uuidString)").setData(Self.splitBillData(bill)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.userID == userID else { return }
                    self.onWriteError?(error.localizedDescription)
                }
            }
    }

    func uploadInitial(_ bill: SplitBill) async throws {
        guard let userID, !AccountDeletionJournal.shared.contains(userID) else { return }
        let ref = database.collection("users").document(userID).collection("budgets")
            .document("split-\(bill.id.uuidString)")
        let remote = try await ref.getDocument(source: .server)
        guard self.userID == userID, !AccountDeletionJournal.shared.contains(userID) else { throw CancellationError() }
        if let existing = Self.decodeSplitBill(remote), existing.updatedAt >= bill.updatedAt { return }
        try await ref.setData(Self.splitBillData(bill))
    }

    private static func entryData(_ entry: CloudEntry) -> [String: Any] {
        ["kind": Int(entry.kind.rawValue), "amount": NSDecimalNumber(decimal: entry.amount).stringValue,
         "categoryID": entry.categoryID?.uuidString as Any? ?? NSNull(),
         "paymentMethodID": entry.paymentMethodID?.uuidString as Any? ?? NSNull(),
         "title": entry.title, "category": entry.category, "date": Timestamp(date: entry.date),
         "note": entry.note, "createdAt": Timestamp(date: entry.createdAt),
         "updatedAt": Timestamp(date: entry.updatedAt),
         "deletedAt": entry.deletedAt.map { Timestamp(date: $0) } ?? NSNull(),
         "placeID": entry.location?.placeID?.uuidString as Any? ?? NSNull(),
         "eventID": entry.eventID?.uuidString as Any? ?? NSNull(),
         "budgetOverrideReason": entry.budgetOverrideReason as Any? ?? NSNull(),
         "locationName": entry.location?.name as Any? ?? NSNull(),
         "latitude": entry.location?.latitude as Any? ?? NSNull(),
         "longitude": entry.location?.longitude as Any? ?? NSNull()]
    }

    private static func budgetData(_ budget: CloudBudget) -> [String: Any] {
        ["month": Timestamp(date: budget.month),
         "amount": NSDecimalNumber(decimal: budget.amount).stringValue,
         "updatedAt": Timestamp(date: budget.updatedAt)]
    }

    private static func categoryBudgetData(_ budget: CategoryBudget) -> [String: Any] {
        ["monthKey": budget.monthKey, "categoryName": budget.categoryName,
         "amount": NSDecimalNumber(decimal: budget.amount).stringValue,
         "updatedAt": Timestamp(date: budget.updatedAt)]
    }

    private static func lifeEventData(_ event: LifeEvent) -> [String: Any] {
        ["eventName": event.name, "eventKind": event.kind.rawValue,
         "budget": NSDecimalNumber(decimal: event.budget).stringValue,
         "startDate": Timestamp(date: event.startDate),
         "endDate": Timestamp(date: event.endDate),
         "completedAt": event.completedAt.map { Timestamp(date: $0) } ?? NSNull(),
         "completionSpent": event.completionSpent.map { NSDecimalNumber(decimal: $0).stringValue } ?? NSNull(),
         "createdAt": Timestamp(date: event.createdAt),
         "updatedAt": Timestamp(date: event.updatedAt)]
    }

    private static func friendData(_ friend: LedgerFriend) -> [String: Any] {
        ["friendName": friend.name, "isArchived": friend.isArchived,
         "createdAt": Timestamp(date: friend.createdAt),
         "updatedAt": Timestamp(date: friend.updatedAt)]
    }

    private static func splitBillData(_ bill: SplitBill) -> [String: Any] {
        ["entryID": bill.entryID.uuidString,
         "totalAmount": NSDecimalNumber(decimal: bill.totalAmount).stringValue,
         "note": bill.note,
         "shares": bill.shares.map { share in
             ["id": share.id.uuidString,
              "friendID": share.friendID?.uuidString as Any? ?? NSNull(),
              "amount": NSDecimalNumber(decimal: share.amount).stringValue,
              "settledAt": share.settledAt.map { Timestamp(date: $0) } ?? NSNull()] as [String: Any]
         },
         "createdAt": Timestamp(date: bill.createdAt),
         "updatedAt": Timestamp(date: bill.updatedAt),
         "deletedAt": bill.deletedAt.map { Timestamp(date: $0) } ?? NSNull()]
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
        let location: LedgerLocation?
        if let name = data["locationName"] as? String,
           let latitude = data["latitude"] as? Double,
           let longitude = data["longitude"] as? Double {
            let candidate = LedgerLocation(placeID: (data["placeID"] as? String).flatMap(UUID.init(uuidString:)),
                                           name: name, latitude: latitude, longitude: longitude)
            location = candidate.isValid ? candidate : nil
        } else {
            location = nil
        }
        var entry = CloudEntry(id: id, kind: kind, amount: amount, title: title, category: category,
                          date: date, note: note, createdAt: createdAt, updatedAt: updatedAt,
                          deletedAt: (data["deletedAt"] as? Timestamp)?.dateValue(), location: location,
                          eventID: (data["eventID"] as? String).flatMap(UUID.init(uuidString:)),
                          budgetOverrideReason: data["budgetOverrideReason"] as? String)
        entry.categoryID = (data["categoryID"] as? String).flatMap(UUID.init(uuidString:))
        entry.paymentMethodID = (data["paymentMethodID"] as? String).flatMap(UUID.init(uuidString:))
        return entry
    }

    private static func decodeBudget(_ snapshot: DocumentSnapshot) -> CloudBudget? {
        guard let data = snapshot.data(),
              let month = (data["month"] as? Timestamp)?.dateValue(),
              let amountText = data["amount"] as? String,
              let amount = Decimal(string: amountText),
              let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else { return nil }
        return CloudBudget(month: month, amount: amount, updatedAt: updatedAt)
    }

    private static func decodeCategoryBudget(_ snapshot: DocumentSnapshot) -> CategoryBudget? {
        guard let data = snapshot.data(),
              let monthKey = data["monthKey"] as? String,
              let categoryName = data["categoryName"] as? String,
              let amountText = data["amount"] as? String,
              let amount = Decimal(string: amountText),
              let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else { return nil }
        let budget = CategoryBudget(monthKey: monthKey, categoryName: categoryName,
                                    amount: amount, updatedAt: updatedAt)
        return budget.isValid && budget.id == snapshot.documentID ? budget : nil
    }

    private static func decodeLifeEvent(_ snapshot: DocumentSnapshot) -> LifeEvent? {
        guard let data = snapshot.data(), snapshot.documentID.hasPrefix("event-"),
              let id = UUID(uuidString: String(snapshot.documentID.dropFirst("event-".count))),
              let name = data["eventName"] as? String,
              let kindText = data["eventKind"] as? String,
              let kind = LifeEventKind(rawValue: kindText),
              let budgetText = data["budget"] as? String,
              let budget = Decimal(string: budgetText),
              let startDate = (data["startDate"] as? Timestamp)?.dateValue(),
              let endDate = (data["endDate"] as? Timestamp)?.dateValue(),
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
              let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else { return nil }
        let event = LifeEvent(id: id, name: name, kind: kind, budget: budget,
                              startDate: startDate, endDate: endDate,
                              completedAt: (data["completedAt"] as? Timestamp)?.dateValue(),
                              completionSpent: (data["completionSpent"] as? String).flatMap { Decimal(string: $0) },
                              createdAt: createdAt, updatedAt: updatedAt)
        return event.isValid ? event : nil
    }

    private static func decodeFriend(_ snapshot: DocumentSnapshot) -> LedgerFriend? {
        guard let data = snapshot.data(), snapshot.documentID.hasPrefix("friend-"),
              let id = UUID(uuidString: String(snapshot.documentID.dropFirst("friend-".count))),
              let name = data["friendName"] as? String,
              let isArchived = data["isArchived"] as? Bool,
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
              let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else { return nil }
        let friend = LedgerFriend(id: id, name: name, isArchived: isArchived,
                                  createdAt: createdAt, updatedAt: updatedAt)
        return friend.isValid ? friend : nil
    }

    private static func decodeSplitBill(_ snapshot: DocumentSnapshot) -> SplitBill? {
        guard let data = snapshot.data(), snapshot.documentID.hasPrefix("split-"),
              let id = UUID(uuidString: String(snapshot.documentID.dropFirst("split-".count))),
              let entryIDText = data["entryID"] as? String,
              let entryID = UUID(uuidString: entryIDText),
              let amountText = data["totalAmount"] as? String,
              let amount = Decimal(string: amountText),
              let note = data["note"] as? String,
              let rawShares = data["shares"] as? [[String: Any]],
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
              let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else { return nil }
        let shares = rawShares.compactMap { raw -> SplitShare? in
            guard let shareIDText = raw["id"] as? String,
                  let shareID = UUID(uuidString: shareIDText),
                  let shareAmountText = raw["amount"] as? String,
                  let shareAmount = Decimal(string: shareAmountText) else { return nil }
            let friendID = (raw["friendID"] as? String).flatMap(UUID.init(uuidString:))
            return SplitShare(id: shareID, friendID: friendID, amount: shareAmount,
                              settledAt: (raw["settledAt"] as? Timestamp)?.dateValue())
        }
        guard shares.count == rawShares.count else { return nil }
        let bill = SplitBill(id: id, entryID: entryID, totalAmount: amount, note: note,
                             shares: shares, createdAt: createdAt, updatedAt: updatedAt,
                             deletedAt: (data["deletedAt"] as? Timestamp)?.dateValue())
        return bill.isValid ? bill : nil
    }
}


extension CloudLedgerSync {
    nonisolated private static func libraryRecords(_ documents: [QueryDocumentSnapshot]) throws -> [CloudLibraryRecord] {
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.documentID, $0.data()) })
        var records: [CloudLibraryRecord] = []
        for document in documents where document.documentID.hasPrefix("library-") {
            let data = document.data()
            guard let kind = (data["libraryKind"] as? String).flatMap(LibraryKind.init(rawValue:)),
                  let id = data["recordID"] as? String,
                  let date = (data["updatedAt"] as? Timestamp)?.dateValue(),
                  let revision = (data["revision"] as? String).flatMap(UUID.init(uuidString:)),
                  let count = data["parts"] as? Int, (0...15).contains(count),
                  let byteCount = data["bytes"] as? Int, let digest = data["digest"] as? String,
                  let deleted = data["deleted"] as? Bool,
                  document.documentID == "library-\(kind.rawValue)-\(id)",
                  (kind == .avatar ? id == "profile" : UUID(uuidString: id) != nil) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var parts: [Data] = []
            for index in 0..<count {
                guard let part = byID["librarypart-\(revision)-\(index)"]?["payload"] as? Data else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                parts.append(part)
            }
            let payload = try CloudLibraryRecord.assemble(parts, byteCount: byteCount, digest: digest)
            guard !deleted || (byteCount == 0 && count == 0) else { throw CocoaError(.fileReadCorruptFile) }
            records.append(.init(kind: kind, id: id, updatedAt: date, revision: revision, payload: deleted ? nil : payload))
        }
        return records
    }

    /// Add references to legacy transactions without changing any financial value
    /// or overwriting a reference/version already supplied by another device.
    func upgradeLibraryReferences(_ entry: CloudEntry) async throws {
        guard let userID, !AccountDeletionJournal.shared.contains(userID) else { throw CancellationError() }
        let generation = listenerGeneration
        let ref = database.collection("users").document(userID).collection("transactions").document(entry.id.uuidString)
        let updatedAt = entry.updatedAt
        let category = entry.category
        let title = entry.title
        let kind = Int(entry.kind.rawValue)
        let categoryID = entry.categoryID?.uuidString
        let methodID = entry.paymentMethodID?.uuidString
        guard categoryID != nil || methodID != nil else { return }
        _ = try await database.runTransaction { transaction, errorPointer -> Any? in
            do {
                let data = try transaction.getDocument(ref).data() ?? [:]
                guard (data["updatedAt"] as? Timestamp)?.dateValue() == updatedAt,
                      data["category"] as? String == category, data["title"] as? String == title,
                      data["kind"] as? Int == kind else { return false }
                var patch: [String: Any] = [:]
                if (data["categoryID"] as? String) == nil, let categoryID { patch["categoryID"] = categoryID }
                if (data["paymentMethodID"] as? String) == nil, let methodID { patch["paymentMethodID"] = methodID }
                if !patch.isEmpty { transaction.updateData(patch, forDocument: ref) }
                return true
            } catch { errorPointer?.pointee = error as NSError; return nil }
        }
        guard self.userID == userID, generation == listenerGeneration else { throw CancellationError() }
    }

    func refreshLibrary() async throws {
        guard let userID else { throw CancellationError() }
        let generation = listenerGeneration
        let snapshot = try await database.collection("users").document(userID).collection("budgets").getDocuments(source: .server)
        guard self.userID == userID, generation == listenerGeneration else { throw CancellationError() }
        onLibraryRecords?(try Self.libraryRecords(snapshot.documents))
    }

    /// Compare and commit in one transaction: an offline device cannot overwrite
    /// a newer record merely by reconnecting. Chunk replacement is atomic too.
    func uploadLibrary(_ record: CloudLibraryRecord) async throws -> Bool {
        guard let userID, !AccountDeletionJournal.shared.contains(userID) else { throw CancellationError() }
        let generation = listenerGeneration
        let collection = database.collection("users").document(userID).collection("budgets")
        let ref = collection.document(record.key)
        let result = try await database.runTransaction { transaction, errorPointer -> Any? in
            do {
                let snapshot = try transaction.getDocument(ref)
                let old = snapshot.data() ?? [:]
                if let date = (old["updatedAt"] as? Timestamp)?.dateValue(),
                   let revision = (old["revision"] as? String).flatMap(UUID.init(uuidString:)) {
                    let previous = CloudLibraryRecord(kind: record.kind, id: record.id, updatedAt: date, revision: revision, payload: nil)
                    if !CloudLibraryJournal.newer(record, than: previous) { return false }
                }
                if let oldRevision = old["revision"] as? String, UUID(uuidString: oldRevision) != nil,
                   let count = old["parts"] as? Int, (0...15).contains(count) {
                    for index in 0..<count { transaction.deleteDocument(collection.document("librarypart-\(oldRevision)-\(index)")) }
                }
                let parts = record.chunks
                for (index, part) in parts.enumerated() {
                    transaction.setData(["payload": part], forDocument: collection.document("librarypart-\(record.revision)-\(index)"))
                }
                transaction.setData(["libraryKind": record.kind.rawValue, "recordID": record.id,
                    "updatedAt": Timestamp(date: record.updatedAt), "revision": record.revision.uuidString,
                    "parts": parts.count, "bytes": record.payload?.count ?? 0, "digest": record.digest,
                    "deleted": record.payload == nil], forDocument: ref)
                return true
            } catch { errorPointer?.pointee = error as NSError; return nil }
        }
        guard self.userID == userID, generation == listenerGeneration,
              !AccountDeletionJournal.shared.contains(userID) else { throw CancellationError() }
        return (result as? Bool) ?? false
    }
}
