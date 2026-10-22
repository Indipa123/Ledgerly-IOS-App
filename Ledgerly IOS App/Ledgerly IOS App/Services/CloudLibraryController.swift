import Foundation

@MainActor
final class CloudLibraryController {
    private let uid: String
    private let repository: CoreDataLedgerRepository
    private let service: CloudLedgerSync
    private let url: URL
    private var journal: CloudLibraryJournal
    private var task: Task<Void, Never>?
    private var flushGeneration = 0
    private var mediaScanned = false
    private var observer: NSObjectProtocol?
    private var active = true
    private var applyingRemote = false
    var onChange: ((Set<LibraryKind>, Set<UUID>) -> Void)?
    var onError: ((String) -> Void)?
    var onPending: ((Int) -> Void)?
    var pendingCount: Int { journal.pending.count + (journal.referencesUpgraded ? 0 : 1) }

    private static func file(_ uid: String) -> URL {
        let key = Data(uid.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibrarySync", isDirectory: true).appendingPathComponent(key + ".json")
    }

    init(uid: String, repository: CoreDataLedgerRepository, service: CloudLedgerSync) throws {
        self.uid = uid; self.repository = repository; self.service = service; url = Self.file(uid)
        if FileManager.default.fileExists(atPath: url.path) {
            journal = try JSONDecoder().decode(CloudLibraryJournal.self, from: Data(contentsOf: url))
        } else { journal = CloudLibraryJournal() }
        observer = NotificationCenter.default.addObserver(forName: AccountPhotoStore.changed, object: nil, queue: .main) { [weak self] notification in
            let owner = notification.object as? String
            Task { @MainActor [weak self] in
                guard let self, self.uid == owner, !self.applyingRemote else { return }
                self.captureMedia(kind: .avatar, id: "profile", payload: AccountPhotoStore.data(self.uid))
            }
        }
    }

    func stop() {
        active = false; flushGeneration += 1; task?.cancel(); task = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    static func erase(_ uid: String) throws {
        let url = file(uid)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try AccountPhotoStore.save(nil, uid: uid)
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: url, options: [.atomic, .completeFileProtection])
        var file = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try file.setResourceValues(values)
        onPending?(pendingCount)
    }

    func capture() {
        guard active, !applyingRemote, !AccountDeletionJournal.shared.contains(uid) else { return }
        do {
            let categories = try repository.fetchCategories().map { ($0.id.uuidString, try CloudLibraryRecord.encode($0)) }
            let payments = try repository.fetchPaymentMethods().map { ($0.id.uuidString, try CloudLibraryRecord.encode($0)) }
            let reminders = try repository.fetchReminders().map { ($0.id.uuidString, try CloudLibraryRecord.encode($0)) }
            let places = try repository.fetchPlaces().map { ($0.id.uuidString, try CloudLibraryRecord.encode($0)) }
            try journal.observe([.category: Dictionary(uniqueKeysWithValues: categories), .payment: Dictionary(uniqueKeysWithValues: payments),
                                 .reminder: Dictionary(uniqueKeysWithValues: reminders), .place: Dictionary(uniqueKeysWithValues: places)])
            if !mediaScanned {
                for entry in try repository.allEntriesForSync() {
                    do {
                    let key = "library-receipt-\(entry.id.uuidString)"
                    if let deleted = entry.deletedAt, journal.records[key]?.payload != nil {
                        try journal.capture(kind: .receipt, id: entry.id.uuidString, payload: nil, at: deleted)
                    } else if entry.deletedAt == nil, let data = try ReceiptImageStore.archiveForSync(for: entry.id) {
                        try journal.capture(kind: .receipt, id: entry.id.uuidString, payload: data, legacy: journal.records[key] == nil)
                    }
                    } catch { onError?("A receipt could not be queued: \(error.localizedDescription)") }
                }
                if let data = AccountPhotoStore.data(uid) {
                    try journal.capture(kind: .avatar, id: "profile", payload: data, legacy: journal.records["library-avatar-profile"] == nil)
                }
            }
            try persist(); mediaScanned = true; flush()
        } catch { onError?(error.localizedDescription) }
    }

    func captureMedia(kind: LibraryKind, id: String, payload: Data?) {
        guard active, !applyingRemote, !AccountDeletionJournal.shared.contains(uid) else { return }
        do { try journal.capture(kind: kind, id: id, payload: payload); try persist(); flush() }
        catch { onError?(error.localizedDescription) }
    }

    func receive(_ records: [CloudLibraryRecord]) {
        guard active, !AccountDeletionJournal.shared.contains(uid) else { return }
        applyingRemote = true
        defer { applyingRemote = false; flush() }
        var changed: Set<LibraryKind> = []
        var changedReminders: Set<UUID> = []
        for record in records.sorted(by: { $0.key < $1.key }) {
            do {
                if journal.records[record.key]?.revision == record.revision {
                    journal.acknowledge(record); continue
                }
                guard journal.accepts(record) else { continue }
                try apply(record)
                journal.accept(record); changed.insert(record.kind)
                if record.kind == .reminder, let id = UUID(uuidString: record.id) { changedReminders.insert(id) }
            } catch { onError?("Could not restore \(record.kind.rawValue): \(error.localizedDescription)") }
        }
        do { try persist() } catch { onError?(error.localizedDescription) }
        if !changed.isEmpty { onChange?(changed, changedReminders) }
    }

    private func apply(_ record: CloudLibraryRecord) throws {
        let decoder = JSONDecoder()
        let id = UUID(uuidString: record.id)
        switch record.kind {
        case .category:
            if let data = record.payload {
                let value = try decoder.decode(LedgerCategory.self, from: data)
                guard value.id == id, !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                try repository.applyLibraryCategory(value)
            } else if let id { try repository.archiveCategory(id: id) }
        case .payment:
            if let data = record.payload {
                let value = try decoder.decode(LedgerPaymentMethod.self, from: data)
                guard value.id == id, !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                try repository.applyLibraryPayment(value)
            } else if let id { try repository.archivePaymentMethod(id: id) }
        case .reminder:
            if let data = record.payload {
                let value = try decoder.decode(LedgerReminder.self, from: data)
                guard value.id == id else { throw CocoaError(.fileReadCorruptFile) }
                try repository.saveReminder(value, acceptingPast: true)
            } else if let id { try repository.deleteReminder(id: id) }
        case .place:
            if let data = record.payload {
                let value = try decoder.decode(LedgerPlace.self, from: data)
                guard value.id == id else { throw CocoaError(.fileReadCorruptFile) }
                try repository.savePlace(value)
            } else if let id { try repository.deletePlace(id: id) }
        case .receipt:
            guard let id else { throw CocoaError(.fileReadCorruptFile) }
            if let data = record.payload { try ReceiptImageStore.saveArchive(data, for: id) }
            else { ReceiptImageStore.delete(for: id) }
        case .avatar:
            try AccountPhotoStore.save(record.payload, uid: uid, preservingEncoded: true)
        }
    }

    func retry() {
        flushGeneration += 1; task?.cancel(); task = nil
        capture(); flush()
    }

    func flush() {
        guard active, journal.bootstrapped, task == nil, !journal.pending.isEmpty || !journal.referencesUpgraded else { return }
        let generation = flushGeneration
        task = Task { [weak self] in
            guard let self else { return }
            var completed = false
            defer {
                if flushGeneration == generation {
                    self.task = nil
                    if completed, active, !journal.pending.isEmpty { flush() }
                }
            }
            do {
                // Capture each revision just before sending; edits made while awaiting
                // the server remain in the durable outbox for the next iteration.
                while active, flushGeneration == generation, !Task.isCancelled, let key = journal.pending.sorted().first,
                      let record = journal.records[key] {
                    let uploaded = try await service.uploadLibrary(record)
                    guard active, flushGeneration == generation, !Task.isCancelled else { return }
                    if uploaded { journal.acknowledge(record); try persist() }
                    else {
                        try await service.refreshLibrary()
                        if journal.records[key]?.revision == record.revision { journal.acknowledge(record); try persist() }
                    }
                }
                if active, flushGeneration == generation, !Task.isCancelled, !journal.referencesUpgraded {
                    for entry in try repository.allEntriesForSync() {
                        try await service.upgradeLibraryReferences(entry)
                        guard active, flushGeneration == generation, !Task.isCancelled else { return }
                    }
                    journal.finishReferenceUpgrade(); try persist()
                }
                completed = true
            } catch {
                guard active, flushGeneration == generation, !Task.isCancelled else { return }
                onError?("Additional cloud sync is waiting: \(error.localizedDescription)")
            }
        }
    }
}
