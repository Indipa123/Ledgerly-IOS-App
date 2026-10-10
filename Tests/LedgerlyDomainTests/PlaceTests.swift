import Foundation
import CoreData
import Testing
@testable import LedgerlyDomain

@MainActor
struct PlaceTests {
    @Test func savedPlaceAndAttachedExpensePersistAndSyncSnapshot() throws {
        let source = CoreDataLedgerRepository(inMemory: true)
        let place = LedgerPlace(id: UUID(), name: "Shop", latitude: 6.9271, longitude: 79.8612)
        try source.savePlace(place)
        let category = try #require(source.fetchCategories().first { $0.kind == .expense })
        let expense = LedgerEntry(id: UUID(), kind: .expense, amount: 430,
                                  title: "Ticket", category: category.name, date: .now,
                                  note: "", categoryID: category.id, location: place.location)
        try source.upsert(expense)
        #expect(try source.fetchPlaces().first?.id == place.id)
        #expect(try source.fetchEntries().first?.location == place.location)

        let cloudEntry = try source.syncEntry(id: expense.id)
        let remote = try #require(cloudEntry)
        let destination = CoreDataLedgerRepository(inMemory: true)
        try destination.applyRemote(remote)
        #expect(try destination.fetchEntries().first?.location == place.location)
        #expect(try destination.fetchPlaces().isEmpty)
    }

    @Test func movingSavedPlacePreservesRecordedExpenseCoordinate() {
        let place = LedgerPlace(id: UUID(), name: "Shop", latitude: 6.92, longitude: 79.86)
        let expense = LedgerEntry(id: UUID(), kind: .expense, amount: 100,
                                  title: "", category: "Food", date: .now, note: "",
                                  location: place.location)
        let moved = LedgerPlace(id: place.id, name: "Shop", latitude: 7.0, longitude: 80.0)
        let points = PlaceCalculations.mapPoints(places: [moved], entries: [expense])
        #expect(points.count == 2)
        #expect(points.first { $0.amount == 100 }?.latitude == 6.92)
        #expect(points.first { $0.id == moved.id.uuidString }?.amount == 0)
    }

    @Test func incomeCanKeepAnUnsavedCurrentLocation() throws {
        let source = CoreDataLedgerRepository(inMemory: true)
        let category = try #require(source.fetchCategories().first { $0.kind == .income })
        let location = LedgerLocation(placeID: nil, name: "Current location",
                                      latitude: 7.2094, longitude: 79.8358)
        let income = LedgerEntry(id: UUID(), kind: .income, amount: 500,
                                 title: "Salary", category: category.name, date: .now,
                                 note: "", categoryID: category.id, location: location)
        try source.upsert(income)
        #expect(try source.fetchEntries().first?.location == location)

        let remote = try #require(try source.syncEntry(id: income.id))
        let destination = CoreDataLedgerRepository(inMemory: true)
        try destination.applyRemote(remote)
        #expect(try destination.fetchEntries().first?.location == location)
        #expect(PlaceCalculations.mapPoints(places: [], entries: [income]).isEmpty)
    }

    @Test func olderStoreMigratesWhenPlaceFieldsAreAdded() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerly-place-migration-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        let oldModel = CoreDataModel.make()
        oldModel.entities = oldModel.entities.filter { $0.name != "SavedPlaceRecord" }
        let transaction = try #require(oldModel.entitiesByName["TransactionRecord"])
        transaction.properties = transaction.properties.filter {
            !["placeID", "locationName", "locationLatitude", "locationLongitude"].contains($0.name)
        }
        let oldStore = NSPersistentContainer(name: "Ledgerly", managedObjectModel: oldModel)
        oldStore.persistentStoreDescriptions = [NSPersistentStoreDescription(url: url)]
        var loadError: Error?
        oldStore.loadPersistentStores { _, error in loadError = error }
        try #require(loadError == nil)
        let budget = NSEntityDescription.insertNewObject(forEntityName: "BudgetRecord",
                                                         into: oldStore.viewContext) as! BudgetRecord
        budget.id = UUID()
        budget.month = .now
        budget.amount = 50
        budget.createdAt = .now
        budget.updatedAt = .now
        try oldStore.viewContext.save()
        for store in oldStore.persistentStoreCoordinator.persistentStores {
            try oldStore.persistentStoreCoordinator.remove(store)
        }

        let newStore = NSPersistentContainer(name: "Ledgerly", managedObjectModel: CoreDataModel.make())
        let description = NSPersistentStoreDescription(url: url)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        newStore.persistentStoreDescriptions = [description]
        loadError = nil
        newStore.loadPersistentStores { _, error in loadError = error }
        try #require(loadError == nil)
        let budgets = try newStore.viewContext.fetch(NSFetchRequest<BudgetRecord>(entityName: "BudgetRecord"))
        #expect(budgets.first?.amount == 50)
        #expect(newStore.managedObjectModel.entitiesByName["SavedPlaceRecord"] != nil)
    }
}
