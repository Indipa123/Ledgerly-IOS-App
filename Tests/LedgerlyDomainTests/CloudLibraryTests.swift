import Foundation
import Testing
@testable import LedgerlyDomain

struct CloudLibraryTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func offlineOutboxSurvivesEncodingAndAcknowledgementDoesNotEraseANewerEdit() throws {
        var journal = CloudLibraryJournal()
        let id = UUID().uuidString
        try journal.capture(kind: .place, id: id, payload: Data("first".utf8), at: date)
        let first = try #require(journal.records.values.first)
        var reopened = try JSONDecoder().decode(CloudLibraryJournal.self, from: JSONEncoder().encode(journal))
        #expect(reopened.pending == [first.key])
        try reopened.capture(kind: .place, id: id, payload: Data("second".utf8), at: date.addingTimeInterval(1))
        reopened.acknowledge(first)
        #expect(reopened.pending.contains(first.key))
        #expect(reopened.records[first.key]?.payload == Data("second".utf8))
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(reopened)) as? [String: Any])
        legacy.removeValue(forKey: "referencesUpgraded")
        let upgraded = try JSONDecoder().decode(CloudLibraryJournal.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!upgraded.referencesUpgraded && upgraded.pending == reopened.pending)
        #expect(upgraded.records == reopened.records)
    }

    @Test func removalPersistsATombstoneAndRejectsAnOlderDeviceCopy() throws {
        var journal = CloudLibraryJournal()
        let id = UUID().uuidString
        try journal.observe([.reminder: [id: Data("old".utf8)]], at: date)
        let old = try #require(journal.records.values.first)
        try journal.observe([.reminder: [:]], at: date.addingTimeInterval(2))
        let removed = try #require(journal.records[old.key])
        #expect(removed.payload == nil && !journal.accepts(old))
        let reopened = try JSONDecoder().decode(CloudLibraryJournal.self, from: JSONEncoder().encode(journal))
        #expect(reopened.records[old.key]?.revision == removed.revision)
        #expect(reopened.pending.contains(old.key))
    }

    @Test func unrelatedDeviceRecordsMergeAndEqualTimeConflictsHaveOneWinner() throws {
        var journal = CloudLibraryJournal()
        let first = CloudLibraryRecord(kind: .place, id: UUID().uuidString, updatedAt: date,
            revision: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, payload: Data("A".utf8))
        let second = CloudLibraryRecord(kind: .place, id: first.id, updatedAt: date,
            revision: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, payload: Data("B".utf8))
        journal.accept(first)
        #expect(journal.accepts(second))
        journal.accept(second)
        #expect(!journal.accepts(first))
        let other = CloudLibraryRecord(kind: .avatar, id: "profile", updatedAt: date, revision: UUID(), payload: Data("photo".utf8))
        journal.accept(other)
        #expect(journal.records.count == 2)
    }

    @Test func legacyBaselineDoesNotWinAgainstPreviouslySyncedChanges() throws {
        var journal = CloudLibraryJournal()
        let id = UUID().uuidString
        try journal.observe([.category: [id: Data("legacy".utf8)]], at: date)
        let old = try #require(journal.records.values.first)
        #expect(old.updatedAt == Date(timeIntervalSince1970: 0))
        let remote = CloudLibraryRecord(kind: .category, id: id, updatedAt: date, revision: UUID(), payload: Data("remote".utf8))
        #expect(journal.accepts(remote))
        journal.accept(remote)
        try journal.observe([.category: [id: Data("remote".utf8)]], at: date.addingTimeInterval(1))
        #expect(journal.pending.isEmpty)
    }

    @Test func attachmentChunksRoundTripAndRejectMissingCorruptOrOversizedContent() throws {
        let payload = Data((0..<600_123).map { UInt8($0 % 251) })
        let record = CloudLibraryRecord(kind: .receipt, id: UUID().uuidString, updatedAt: date, revision: UUID(), payload: payload)
        #expect(record.chunks.count == 3)
        #expect(try CloudLibraryRecord.assemble(record.chunks, byteCount: payload.count, digest: record.digest) == payload)
        #expect(throws: (any Error).self) { try CloudLibraryRecord.assemble(Array(record.chunks.dropLast()), byteCount: payload.count, digest: record.digest) }
        #expect(throws: (any Error).self) { try CloudLibraryRecord.assemble(Array(record.chunks.reversed()), byteCount: payload.count, digest: record.digest) }
        #expect(throws: (any Error).self) { try CloudLibraryRecord.assemble(record.chunks, byteCount: payload.count, digest: "bad") }
        var journal = CloudLibraryJournal()
        #expect(throws: (any Error).self) {
            try journal.capture(kind: .receipt, id: UUID().uuidString, payload: Data(count: CloudLibraryRecord.maximumBytes + 1))
        }
        #expect(journal.records.isEmpty)
    }

    @Test func multipleReceiptPagesRetainOrderAndEnforceBounds() throws {
        let pages = (1...10).map { Data("page \($0)".utf8) }
        let archive = try ReceiptPageArchive(pages: pages)
        #expect(try ReceiptPageArchive.decode(JSONEncoder().encode(archive)).pages == pages)
        #expect(throws: (any Error).self) { try ReceiptPageArchive(pages: []) }
        #expect(throws: (any Error).self) { try ReceiptPageArchive(pages: pages + [Data("11".utf8)]) }
        #expect(throws: (any Error).self) { try ReceiptPageArchive(pages: [Data(count: ReceiptPageArchive.maximumPageBytes + 1)]) }
        let forged = try JSONSerialization.data(withJSONObject: ["pages": [""]])
        #expect(throws: (any Error).self) { try ReceiptPageArchive.decode(forged) }
    }

    @MainActor @Test func builtInIdentitiesAreStableAndRemoteLibraryMergesPreserveTransactionLinks() throws {
        let first = CoreDataLedgerRepository(inMemory: true)
        let second = CoreDataLedgerRepository(inMemory: true)
        #expect(Set(try first.fetchCategories().map(\.id)) == Set(try second.fetchCategories().map(\.id)))
        #expect(Set(try first.fetchPaymentMethods().map(\.id)) == Set(try second.fetchPaymentMethods().map(\.id)))
        let category = try #require(first.fetchCategories().first { $0.kind == .expense })
        let method = try #require(first.fetchPaymentMethods().first)
        let id = UUID()
        try first.upsert(.init(id: id, kind: .expense, amount: Decimal(string: "125.55")!, title: "Synthetic",
            category: category.name, date: date, note: "Unchanged", categoryID: category.id, paymentMethodID: method.id))
        let receivedCategory = LedgerCategory(id: UUID(), name: category.name, kind: category.kind,
            isSystem: false, isArchived: false, sortIndex: 100)
        let receivedMethod = LedgerPaymentMethod(id: UUID(), name: method.name, kind: method.kind,
            lastFour: "1234", isArchived: false, sortIndex: 100)
        try first.applyLibraryCategory(receivedCategory)
        try first.applyLibraryPayment(receivedMethod)
        let saved = try #require(first.fetchEntries().first)
        #expect(saved.categoryID == receivedCategory.id && saved.paymentMethodID == receivedMethod.id)
        #expect(saved.amount == Decimal(string: "125.55")! && saved.note == "Unchanged" && saved.date == date)
        var cloud = try #require(try first.syncEntry(id: id))
        cloud.paymentMethodID = receivedMethod.id
        try second.applyRemote(cloud)
        #expect(try second.fetchEntries().first?.paymentMethodID == receivedMethod.id)
        var renamed = receivedCategory
        renamed.name = "Renamed on another device"
        try first.applyLibraryCategory(renamed)
        var lateEntry = CloudEntry(id: UUID(), kind: .expense, amount: 99, title: "Late transaction",
            category: category.name, date: date, note: "", createdAt: date, updatedAt: date, deletedAt: nil)
        lateEntry.categoryID = renamed.id
        try first.applyRemote(lateEntry)
        #expect(try first.fetchEntries().first { $0.id == lateEntry.id }?.category == renamed.name)
        #expect(try first.fetchCategories().first { $0.id == renamed.id }?.name == renamed.name)
    }

    @MainActor @Test func expiredOneTimeReminderCanRestoreWithoutBeingScheduledAsNew() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let reminder = LedgerReminder(id: UUID(), title: "Past reminder", amount: 100, frequency: .once,
            dayOfMonth: 1, weekday: 1, date: Date(timeIntervalSince1970: 1), hour: 12, minute: 0, isPaused: false)
        #expect(!reminder.isValid)
        try repository.saveReminder(reminder, acceptingPast: true)
        #expect(try repository.fetchReminders().first?.nextOccurrence() == nil)
    }
}
