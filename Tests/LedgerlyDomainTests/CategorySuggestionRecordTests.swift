import CoreData
import Foundation
import Testing
@testable import LedgerlyDomain

@MainActor
struct CategorySuggestionRecordTests {
    private func record(category: LedgerCategory, accepted: Bool = true) -> CategorySuggestionRecord {
        .init(source: .personalModel, suggestedCategoryID: accepted ? category.id : UUID(),
              suggestedCategoryName: accepted ? category.name : "Another category",
              savedCategoryID: category.id, savedCategoryName: category.name,
              kind: category.kind.rawValue, recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
              modelVersion: UUID())
    }

    @Test func outcomesAndCategoryIdentitySurvivePersistence() throws {
        let category = LedgerCategory(id: UUID(), name: "Groceries", kind: .expense,
                                      isSystem: true, isArchived: false, sortIndex: 0)
        for accepted in [true, false] {
            let original = record(category: category, accepted: accepted)
            let decoded = try JSONDecoder().decode(CategorySuggestionRecord.self,
                                                   from: JSONEncoder().encode(original))
            #expect(decoded == original)
            #expect(decoded.wasAccepted == accepted)
            #expect(!decoded.categoryChanged(categoryID: category.id, kind: 0))
            #expect(decoded.categoryChanged(categoryID: UUID(), kind: 0))
            #expect(decoded.categoryChanged(categoryID: category.id, kind: 1))
        }
        for source in [CategoryMatch.exact, .similar, .model, .personalModel, .place] {
            #expect(try JSONDecoder().decode(CategoryMatch.self, from: JSONEncoder().encode(source)) == source)
            #expect(!source.label.isEmpty)
        }
    }

    @Test func editsRenameAndUndoKeepFirstSaveEvidence() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        var category = try #require(repository.fetchCategories().first { $0.kind == .expense })
        let original = record(category: category)
        let id = UUID()
        try repository.upsert(.init(id: id, kind: .expense, amount: 20, title: "Example",
                                    category: category.name, date: .now, note: "",
                                    categoryID: category.id, categorySuggestion: original))
        category.name = "Renamed category"
        try repository.saveCategory(category)
        let renamed = try #require(repository.fetchEntries().first)
        #expect(renamed.category == category.name)
        #expect(renamed.categorySuggestion == original)
        #expect(!original.categoryChanged(categoryID: renamed.categoryID, kind: renamed.kind.rawValue))
        let other = try #require(repository.fetchCategories().first { $0.kind == .expense && $0.id != category.id })
        // Other save paths may omit metadata or supply a replacement. Neither rewrites history.
        for replacement in [nil, record(category: other)] {
            try repository.upsert(.init(id: id, kind: .expense, amount: 25, title: "Edited",
                                        category: other.name, date: .now, note: "",
                                        categoryID: other.id, categorySuggestion: replacement))
            #expect(try repository.fetchEntries().first?.categorySuggestion == original)
        }
        try repository.softDelete(id: id)
        try repository.restoreDeleted(id: id)
        let restored = try #require(repository.fetchEntries().first)
        #expect(restored.categorySuggestion == original)
        #expect(original.categoryChanged(categoryID: restored.categoryID, kind: restored.kind.rawValue))
        #expect(restored.amount == 25)
    }

    @Test func cloudChangesPreserveLocalEvidenceButDoNotCreateItElsewhere() throws {
        let local = CoreDataLedgerRepository(inMemory: true)
        let otherDevice = CoreDataLedgerRepository(inMemory: true)
        let category = try #require(local.fetchCategories().first { $0.kind == .expense })
        let id = UUID()
        let evidence = record(category: category, accepted: false)
        try local.upsert(.init(id: id, kind: .expense, amount: 430, title: "Example",
                               category: category.name, date: .now, note: "",
                               categoryID: category.id, categorySuggestion: evidence))
        let upload = try #require(try local.syncEntry(id: id))
        try otherDevice.applyRemote(upload)
        #expect(try otherDevice.fetchEntries().first?.categorySuggestion == nil)
        let remote = CloudEntry(id: id, kind: .income, amount: 500, title: "Changed remotely",
                                category: "Salary", date: upload.date, note: "",
                                createdAt: upload.createdAt, updatedAt: upload.updatedAt.addingTimeInterval(60),
                                deletedAt: nil)
        try local.applyRemote(remote)
        let changed = try #require(local.fetchEntries().first)
        #expect(changed.categorySuggestion == evidence)
        #expect(evidence.categoryChanged(categoryID: changed.categoryID, kind: changed.kind.rawValue))
    }

    @Test func legacyEntriesNeverAcquireInventedFirstSaveEvidence() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let category = try #require(repository.fetchCategories().first { $0.kind == .expense })
        let id = UUID()
        var entry = LedgerEntry(id: id, kind: .expense, amount: 10, title: "Old entry",
                                category: category.name, date: .now, note: "", categoryID: category.id)
        try repository.upsert(entry)
        entry.categorySuggestion = record(category: category)
        try repository.upsert(entry)
        #expect(try repository.fetchEntries().first?.categorySuggestion == nil)
    }

    @Test func previousSQLiteSchemaMigratesWithoutChangingFinancialRecords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("legacy.sqlite")
        let previous = CoreDataModel.make(includeSuggestionHistory: false)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: previous)
        let oldStore = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType,
                                                          configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let id = UUID()
        let row = NSEntityDescription.insertNewObject(forEntityName: "TransactionRecord", into: context)
        row.setValuesForKeys(["id": id, "kind": Int16(0), "amount": NSDecimalNumber(string: "430.55"),
                              "title": "Legacy receipt", "category": "Transport", "date": Date.now,
                              "note": "Keep this note", "createdAt": Date.now, "updatedAt": Date.now])
        try context.save()
        context.reset()
        try coordinator.remove(oldStore)

        try CoreDataLedgerRepository.migrateSuggestionHistoryIfNeeded(at: url)
        try CoreDataLedgerRepository.migrateSuggestionHistoryIfNeeded(at: url) // Idempotent.
        let current = NSPersistentStoreCoordinator(managedObjectModel: CoreDataModel.make())
        let migrated = try current.addPersistentStore(ofType: NSSQLiteStoreType,
                                                       configurationName: nil, at: url)
        defer { try? current.remove(migrated) }
        let migratedContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        migratedContext.persistentStoreCoordinator = current
        let saved = try #require(migratedContext.fetch(NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")).first)
        #expect(saved.id == id)
        #expect(saved.amount == NSDecimalNumber(string: "430.55"))
        #expect(saved.note == "Keep this note")
        #expect(saved.categorySuggestionData == nil)
    }
}
