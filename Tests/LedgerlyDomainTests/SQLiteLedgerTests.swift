import Foundation
import CoreData
import Testing
@testable import LedgerlyDomain

@MainActor
struct SQLiteLedgerTests {
    @Test func legacyBuiltInIDsMigrateWithoutChangingFinancialValuesOrCustomCategories() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ledgerly-legacy-library-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Synthetic.sqlite")
        let oldCategory = UUID(), oldMethod = UUID(), customID = UUID(), entryID = UUID()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        try autoreleasepool {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: CoreDataModel.make())
            let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: nil)
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            for (id, name, system, index) in [(oldCategory, "Renamed food", true, 0), (customID, "Custom", false, 99)] {
                let row = NSEntityDescription.insertNewObject(forEntityName: "CategoryRecord", into: context) as! CategoryRecord
                row.id = id; row.name = name; row.kind = 0; row.isSystem = system; row.isArchived = false; row.sortIndex = Int16(index)
            }
            let method = NSEntityDescription.insertNewObject(forEntityName: "PaymentMethodRecord", into: context) as! PaymentMethodRecord
            method.id = oldMethod; method.name = "Cash"; method.kind = 0; method.sortIndex = 0; method.isArchived = false
            let entry = NSEntityDescription.insertNewObject(forEntityName: "TransactionRecord", into: context) as! TransactionRecord
            entry.id = entryID; entry.kind = 0; entry.amount = NSDecimalNumber(string: "125.55")
            entry.title = "Synthetic"; entry.category = "Renamed food"; entry.categoryID = oldCategory
            entry.paymentMethodID = oldMethod; entry.note = "Original note"; entry.date = date
            entry.createdAt = date; entry.updatedAt = date
            try context.save(); context.reset(); try coordinator.remove(store)
        }
        try autoreleasepool {
            let repository = CoreDataLedgerRepository(storeURL: url)
            let saved = try #require(repository.fetchEntries().first)
            #expect(saved.categoryID == StableLibraryID.make("category-0-0"))
            #expect(saved.paymentMethodID == StableLibraryID.make("payment-0"))
            #expect(saved.category == "Renamed food" && saved.amount == Decimal(string: "125.55")!)
            #expect(saved.note == "Original note" && saved.date == date)
            #expect(try repository.syncEntry(id: entryID)?.updatedAt == date)
            #expect(try repository.fetchCategories().contains { $0.id == customID && !$0.isSystem })
        }
    }

    @Test func isolatedSQLiteReopenPreservesAmountsTombstonesAndLocalEvidence() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ledgerly-sqlite-regression-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Synthetic.sqlite")
        let id = UUID()
        let deletedID = UUID()
        try autoreleasepool {
            let repository = CoreDataLedgerRepository(storeURL: url)
            let category = try #require(repository.fetchCategories().first { $0.kind == .expense })
            let evidence = CategorySuggestionRecord(source: .exact, suggestedCategoryID: category.id,
                suggestedCategoryName: category.name, savedCategoryID: category.id,
                savedCategoryName: category.name, kind: 0, recordedAt: .now)
            try repository.upsert(.init(id: id, kind: .expense, amount: Decimal(string: "125.55")!,
                title: "Synthetic", category: category.name, date: .now, note: "Local evidence",
                categoryID: category.id, categorySuggestion: evidence))
            try repository.upsert(.init(id: deletedID, kind: .expense, amount: 999, title: "Deleted synthetic",
                category: category.name, date: .now, note: "", categoryID: category.id))
            try repository.softDelete(id: deletedID)
        }
        try autoreleasepool {
            let reopened = CoreDataLedgerRepository(storeURL: url)
            let rows = try reopened.fetchEntries()
            #expect(rows.count == 1)
            let entry = try #require(rows.first)
            #expect(entry.id == id && entry.amount == Decimal(string: "125.55")!)
            #expect(entry.categorySuggestion?.source == .exact && entry.note == "Local evidence")
            #expect(try reopened.syncEntry(id: deletedID)?.deletedAt != nil)
            try reopened.restoreDeleted(id: deletedID)
            #expect(try reopened.fetchEntries().count == 2)
        }
    }
}
