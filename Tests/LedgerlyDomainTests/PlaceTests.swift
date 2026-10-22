import Foundation
import CoreData
import Testing
@testable import LedgerlyDomain

@MainActor
struct PlaceTests {
    @Test func placeDetailsMatchMapTotalsWithoutMovingHistoricalExpenses() throws {
        let place = LedgerPlace(id: UUID(), name: "Shop", latitude: 6.92, longitude: 79.86)
        let sameCoordinate = LedgerPlace(id: UUID(), name: "Nearby shop", latitude: 6.92, longitude: 79.86)
        func entry(_ amount: Decimal, _ location: LedgerLocation, kind: EntryKind = .expense) -> LedgerEntry {
            .init(id: UUID(), kind: kind, amount: amount, title: "", category: "Other",
                  date: Date(timeIntervalSince1970: 1_000_000), note: "", location: location)
        }
        let history = [entry(100, place.location), entry(250, place.location),
                       entry(900, place.location, kind: .income), entry(50, sameCoordinate.location)]
        let details = PlaceCalculations.expenses(at: place, in: history)
        let mapPoint = try #require(PlaceCalculations.mapPoints(places: [place, sameCoordinate], entries: history)
            .first { $0.id == place.id.uuidString })
        #expect(details.count == mapPoint.count)
        #expect(details.reduce(Decimal.zero) { $0 + $1.amount } == mapPoint.amount)
        #expect(mapPoint.amount == 350)
        let moved = LedgerPlace(id: place.id, name: "Moved shop", latitude: 7.0, longitude: 80.0)
        #expect(PlaceCalculations.expenses(at: moved, in: history).isEmpty)
        var renamed = place
        renamed.name = "New shop name"
        #expect(PlaceCalculations.expenses(at: renamed, in: history).count == 2)
    }

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
        #expect(PlaceSpendingPattern.analyze(entries: [expense], place: moved).recordedCount == 0)
    }

    @Test func placePatternUsesRecentExpensesAndResistsOutliers() {
        let place = LedgerPlace(id: UUID(), name: "Keells", latitude: 6.92, longitude: 79.86)
        let otherPlace = LedgerPlace(id: UUID(), name: "Other", latitude: 6.93, longitude: 79.87)
        let groceries = UUID()
        let dining = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)
        func entry(_ amount: Decimal, _ categoryID: UUID, _ daysAgo: Double,
                   place recordedPlace: LedgerPlace? = nil, kind: EntryKind = .expense) -> LedgerEntry {
            LedgerEntry(id: UUID(), kind: kind, amount: amount, title: "Purchase",
                        category: "Category", date: now.addingTimeInterval(-daysAgo * 86_400),
                        note: "", categoryID: categoryID, location: (recordedPlace ?? place).location)
        }
        let history = [entry(100, groceries, 1), entry(200, groceries, 2),
                       entry(300, groceries, 3), entry(400, groceries, 4),
                       entry(5_000, dining, 5), entry(900, dining, 2, place: otherPlace),
                       entry(700, groceries, 2, kind: .income),
                       entry(800, dining, -1)]
        let pattern = PlaceSpendingPattern.analyze(entries: history, place: place,
            activeCategoryIDs: [groceries, dining], asOf: now)
        #expect(pattern.recordedCount == 5)
        #expect(pattern.typicalAmount == 300)
        #expect(pattern.categoryID == groceries)
        #expect(pattern.categoryExampleCount == 4)
        let forgotten = PlaceSpendingPattern.analyze(entries: history, place: place,
            activeCategoryIDs: [groceries, dining],
            excludedCategoryEntryIDs: Set(history.prefix(4).map(\.id)), asOf: now)
        #expect(forgotten.typicalAmount == 300)
        #expect(forgotten.categoryID == nil)
    }

    @Test func placePatternAbstainsWithTooLittleOrMixedHistory() {
        let place = LedgerPlace(id: UUID(), name: "Cafe", latitude: 6.92, longitude: 79.86)
        let food = UUID()
        let transport = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let first = LedgerEntry(id: UUID(), kind: .expense, amount: 200, title: "Lunch",
                                category: "Food", date: now, note: "", categoryID: food,
                                location: place.location)
        let second = LedgerEntry(id: UUID(), kind: .expense, amount: 250, title: "Ride",
                                 category: "Transport", date: now, note: "",
                                 categoryID: transport, location: place.location)
        let one = PlaceSpendingPattern.analyze(entries: [first], place: place,
            activeCategoryIDs: [food, transport], asOf: now)
        #expect(one.categoryID == nil)
        #expect(one.typicalAmount == nil)
        let mixed = PlaceSpendingPattern.analyze(entries: [first, second], place: place,
            activeCategoryIDs: [food, transport], asOf: now)
        #expect(mixed.categoryID == nil)
        #expect(mixed.typicalAmount == nil)
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
        oldModel.entities = oldModel.entities.filter {
            $0.name != "SavedPlaceRecord" && $0.name != "LifeEventRecord" &&
                $0.name != "FriendRecord" && $0.name != "SplitBillRecord" &&
                $0.name != "SplitShareRecord"
        }
        let transaction = try #require(oldModel.entitiesByName["TransactionRecord"])
        transaction.properties = transaction.properties.filter {
            !["placeID", "locationName", "locationLatitude", "locationLongitude",
              "eventID", "budgetOverrideReason"].contains($0.name)
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
        #expect(newStore.managedObjectModel.entitiesByName["LifeEventRecord"] != nil)
        #expect(newStore.managedObjectModel.entitiesByName["FriendRecord"] != nil)
        #expect(newStore.managedObjectModel.entitiesByName["SplitBillRecord"] != nil)
    }
}
