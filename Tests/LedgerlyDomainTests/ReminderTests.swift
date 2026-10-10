import Foundation
import CoreData
import Testing
@testable import LedgerlyDomain

@MainActor
@Suite("Local reminders and budget alerts")
struct ReminderTests {
    @Test func existingStoreMigratesWhenRemindersAreAdded() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerly-reminder-migration-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        let oldModel = CoreDataModel.make()
        oldModel.entities = oldModel.entities.filter { $0.name != "ReminderRecord" }
        let oldStore = NSPersistentContainer(name: "Ledgerly", managedObjectModel: oldModel)
        oldStore.persistentStoreDescriptions = [NSPersistentStoreDescription(url: url)]
        var loadError: Error?
        oldStore.loadPersistentStores { _, error in loadError = error }
        try #require(loadError == nil)
        let budget = NSEntityDescription.insertNewObject(forEntityName: "BudgetRecord",
                                                         into: oldStore.viewContext) as! BudgetRecord
        budget.id = UUID()
        budget.month = .now
        budget.amount = 42
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
        #expect(budgets.first?.amount == 42)
        #expect(newStore.managedObjectModel.entitiesByName["ReminderRecord"] != nil)
    }

    @Test func reminderEditPauseAndDeletePersist() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        var reminder = LedgerReminder(id: UUID(), title: "Mobile bill", amount: 1_890,
                                      frequency: .monthly, dayOfMonth: 12, weekday: 2,
                                      date: .now, hour: 9, minute: 30, isPaused: false)
        try repository.saveReminder(reminder)
        #expect(try repository.fetchReminders().first?.title == "Mobile bill")
        reminder.amount = 2_000
        reminder.isPaused = true
        try repository.saveReminder(reminder)
        let saved = try #require(repository.fetchReminders().first)
        #expect(saved.amount == 2_000)
        #expect(saved.isPaused)
        #expect(saved.dateComponents.day == 12)
        #expect(saved.dateComponents.hour == 9)
        try repository.deleteReminder(id: reminder.id)
        #expect(try repository.fetchReminders().isEmpty)
    }

    @Test func budgetWarningsFireOnlyOnCrossings() {
        let budget: Decimal = 1_000
        #expect(BudgetAlertDecision.crossing(from: 700, to: 800, budget: budget) == .warning)
        #expect(BudgetAlertDecision.crossing(from: 800, to: 900, budget: budget) == .none)
        #expect(BudgetAlertDecision.crossing(from: 900, to: 1_000, budget: budget) == .overBudget)
        #expect(BudgetAlertDecision.crossing(from: 900, to: 1_001, budget: budget) == .overBudget)
        #expect(BudgetAlertDecision.crossing(from: 0, to: 1_200, budget: budget) == .overBudget)
        #expect(BudgetAlertDecision.crossing(from: 0, to: 500, budget: 0) == .none)
    }
}
