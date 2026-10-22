import Foundation
import CoreData

@MainActor
protocol LedgerRepository {
    func fetchEntries() throws -> [LedgerEntry]
    func fetchCurrentBudget() throws -> Decimal
    func upsert(_ entry: LedgerEntry) throws
    func markCategoryReviewed(_ entry: LedgerEntry) throws -> Bool
    func reopenCategoryReview(_ entry: LedgerEntry) throws -> Bool
    func softDelete(id: UUID) throws
    func restoreDeleted(id: UUID) throws
    func setCurrentBudget(_ amount: Decimal) throws
    func fetchCategoryBudgets(monthKey: String) throws -> [CategoryBudget]
    func setCategoryBudget(_ budget: CategoryBudget) throws
    func fetchLifeEvents() throws -> [LifeEvent]
    func saveLifeEvent(_ event: LifeEvent) throws
    func fetchFriends() throws -> [LedgerFriend]
    func saveFriend(_ friend: LedgerFriend) throws
    func fetchSplitBills() throws -> [SplitBill]
    func saveSplitBill(_ bill: SplitBill) throws
    func deleteSplitBill(id: UUID) throws -> SplitBill?
    func fetchCategories() throws -> [LedgerCategory]
    func saveCategory(_ category: LedgerCategory) throws
    func archiveCategory(id: UUID) throws
    func fetchPaymentMethods() throws -> [LedgerPaymentMethod]
    func savePaymentMethod(_ method: LedgerPaymentMethod) throws
    func archivePaymentMethod(id: UUID) throws
    func fetchReminders() throws -> [LedgerReminder]
    func saveReminder(_ reminder: LedgerReminder) throws
    func deleteReminder(id: UUID) throws
    func fetchPlaces() throws -> [LedgerPlace]
    func savePlace(_ place: LedgerPlace) throws
    func deletePlace(id: UUID) throws
}

enum LedgerDataError: LocalizedError {
    case duplicateName, missingCategory, wrongCategoryKind, invalidLastFour, invalidReminder, invalidPlace, invalidLocation, invalidCategoryBudget, invalidLifeEvent, invalidFriend, invalidSplit
    var errorDescription: String? {
        switch self {
        case .duplicateName: "That name is already in use."
        case .missingCategory: "Choose an active category."
        case .wrongCategoryKind: "The category must match the transaction type."
        case .invalidLastFour: "Enter exactly four digits for the card label."
        case .invalidReminder: "Enter a title, valid amount, and future date for a one-time reminder."
        case .invalidPlace: "Enter a place name and valid coordinates."
        case .invalidLocation: "Choose a valid location for this transaction."
        case .invalidCategoryBudget: "Choose an expense category and a valid monthly limit."
        case .invalidLifeEvent: "Enter an event name, a positive budget, and an end date after its start date."
        case .invalidFriend: "Enter a friend's name."
        case .invalidSplit: "Choose an expense and valid shares that add up to its total."
        }
    }
}

@MainActor
final class CoreDataLedgerRepository: LedgerRepository {
    private let container: NSPersistentContainer

    func receiptIDsForAccountDeletion() throws -> Set<UUID> {
        let request = NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")
        return Set(try container.viewContext.fetch(request).map(\.id))
    }

    func eraseForAccountDeletion() throws {
        let context = container.viewContext
        for entity in container.managedObjectModel.entities {
            guard let name = entity.name else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.includesPropertyValues = false
            for object in try context.fetch(request) { context.delete(object) }
        }
        try context.save()
        context.reset()
    }

    /// Receipt filenames are legacy transaction IDs shared by stores. Keep images
    /// referenced by any other account instead of deleting another account's attachment.
    static func protectedReceiptIDs(excluding uid: String, includeClaimedGuest: Bool) throws -> Set<UUID> {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let safeID = Data(uid.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        let ownName = "Ledgerly-account-\(safeID).sqlite"
        var urls = FileManager.default.fileExists(atPath: folder.path)
            ? try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) : []
        urls = urls.filter { $0.lastPathComponent.hasPrefix("Ledgerly-account-") &&
            $0.pathExtension == "sqlite" && $0.lastPathComponent != ownName }
        let guestURL = NSPersistentContainer.defaultDirectoryURL().appendingPathComponent("Ledgerly.sqlite")
        if !includeClaimedGuest, FileManager.default.fileExists(atPath: guestURL.path) { urls.append(guestURL) }
        var ids: Set<UUID> = []
        for url in Set(urls) {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType, at: url, options: [NSReadOnlyPersistentStoreOption: true])
            let current = CoreDataModel.make()
            let model = current.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
                ? current : CoreDataModel.make(includeSuggestionHistory: false)
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType,
                configurationName: nil, at: url, options: [NSReadOnlyPersistentStoreOption: true])
            defer { try? coordinator.remove(store) }
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            let request = NSFetchRequest<NSDictionary>(entityName: "TransactionRecord")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id"]
            for result in try context.fetch(request) {
                if let id = result["id"] as? UUID { ids.insert(id) }
            }
        }
        return ids
    }

    /// An explicit URL permits isolated SQLite checks without opening an account store.
    /// In-memory storage takes precedence; normal app callers use the account/default path.
    init(inMemory: Bool = false, accountID: String? = nil, storeURL: URL? = nil) {
        container = NSPersistentContainer(name: "Ledgerly", managedObjectModel: CoreDataModel.make())
        container.persistentStoreDescriptions.forEach {
            $0.shouldMigrateStoreAutomatically = true
            $0.shouldInferMappingModelAutomatically = true
            if inMemory { $0.type = NSInMemoryStoreType }
            else if let storeURL { $0.url = storeURL }
            else if let accountID {
                let safeID = Data(accountID.utf8).base64EncodedString()
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "+", with: "-")
                let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                $0.url = folder.appendingPathComponent("Ledgerly-account-\(safeID).sqlite")
            }
        }
        do {
            for description in container.persistentStoreDescriptions where description.type == NSSQLiteStoreType {
                if let url = description.url { try Self.migrateSuggestionHistoryIfNeeded(at: url) }
            }
        } catch {
            assertionFailure("Could not migrate local finance data: \(error)")
            return
        }
        container.loadPersistentStores { _, error in
            if let error { assertionFailure("Persistent store: \(error)") }
        }
        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        do {
            try seedDefaults()
            try linkLegacyCategories()
        } catch {
            assertionFailure("Could not prepare local finance data: \(error)")
        }
    }

    /// Programmatic models have no bundled .mom versions for automatic source discovery.
    /// Supply the exact predecessor explicitly and replace only after migration succeeds.
    static func migrateSuggestionHistoryIfNeeded(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: url, options: nil)
        let destination = CoreDataModel.make()
        guard !destination.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else { return }
        let source = CoreDataModel.make(includeSuggestionHistory: false)
        guard source.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else { return }
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: source, destinationModel: destination)
        let temporary = url.deletingLastPathComponent().appendingPathComponent("Ledgerly-migration-\(UUID()).sqlite")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: destination)
        defer { try? coordinator.destroyPersistentStore(at: temporary, type: .sqlite) }
        let manager = NSMigrationManager(sourceModel: source, destinationModel: destination)
        try manager.migrateStore(from: url, sourceType: NSSQLiteStoreType, options: nil,
                                 with: mapping, toDestinationURL: temporary,
                                 destinationType: NSSQLiteStoreType, destinationOptions: nil)
        try coordinator.replacePersistentStore(at: url, destinationOptions: nil,
                                               withPersistentStoreFrom: temporary, sourceOptions: nil,
                                               ofType: NSSQLiteStoreType)
    }

    func fetchEntries() throws -> [LedgerEntry] {
        let categoryNames = Dictionary(uniqueKeysWithValues: try fetchCategories().map { ($0.id, $0.name) })
        let request = NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.sortDescriptors = [
            NSSortDescriptor(key: "date", ascending: false),
            NSSortDescriptor(key: "createdAt", ascending: false)
        ]
        return try container.viewContext.fetch(request).compactMap { row in
            guard let kind = EntryKind(rawValue: row.kind) else { return nil }
            let metadata = (try? CategoryHistoryMetadata.decode(row.categorySuggestionData)) ?? .init()
            return LedgerEntry(id: row.id, kind: kind, amount: row.amount.decimalValue,
                               title: row.title, category: row.categoryID.flatMap { categoryNames[$0] } ?? row.category,
                               date: row.date, note: row.note,
                               categoryID: row.categoryID, paymentMethodID: row.paymentMethodID,
                               location: Self.location(from: row), eventID: row.eventID,
                               budgetOverrideReason: row.budgetOverrideReason,
                               categorySuggestion: metadata.firstSave, categoryChanges: metadata.changes)
        }
    }

    func fetchCurrentBudget() throws -> Decimal {
        let request = NSFetchRequest<BudgetRecord>(entityName: "BudgetRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "month == %@", Self.monthStart() as NSDate)
        return try container.viewContext.fetch(request).first?.amount.decimalValue ?? 0
    }

    func upsert(_ entry: LedgerEntry) throws {
        if let location = entry.location, !location.isValid { throw LedgerDataError.invalidLocation }
        if let eventID = entry.eventID {
            guard entry.kind == .expense,
                  try fetchLifeEvents().contains(where: { $0.id == eventID && $0.completedAt == nil })
            else { throw LedgerDataError.invalidLifeEvent }
        }
        let context = container.viewContext
        if let categoryID = entry.categoryID {
            let categoryRequest = NSFetchRequest<CategoryRecord>(entityName: "CategoryRecord")
            categoryRequest.fetchLimit = 1
            categoryRequest.predicate = NSPredicate(format: "id == %@", categoryID as CVarArg)
            guard let category = try context.fetch(categoryRequest).first, !category.isArchived else {
                throw LedgerDataError.missingCategory
            }
            guard category.kind == entry.kind.rawValue else { throw LedgerDataError.wrongCategoryKind }
        }
        let request = NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", entry.id as CVarArg)
        do {
            let row = try context.fetch(request).first
                ?? (NSEntityDescription.insertNewObject(forEntityName: "TransactionRecord", into: context) as! TransactionRecord)
            if row.isInserted {
                row.id = entry.id
                row.createdAt = .now
                // First-save evidence is immutable, local and absent on legacy/cloud-only entries.
                row.categorySuggestionData = try JSONEncoder().encode(
                    CategoryHistoryMetadata(firstSave: entry.categorySuggestion))
            } else {
                var metadata = try CategoryHistoryMetadata.decode(row.categorySuggestionData)
                let categoryNames = Dictionary(uniqueKeysWithValues: try fetchCategories().map { ($0.id, $0.name) })
                metadata.recordChange(
                    from: .init(categoryID: row.categoryID,
                                name: row.categoryID.flatMap { categoryNames[$0] } ?? row.category, kind: row.kind),
                    to: .init(categoryID: entry.categoryID,
                              name: entry.categoryID.flatMap { categoryNames[$0] } ?? entry.category,
                              kind: entry.kind.rawValue), origin: .thisDevice)
                row.categorySuggestionData = try JSONEncoder().encode(metadata)
            }
            row.kind = entry.kind.rawValue
            row.amount = NSDecimalNumber(decimal: entry.amount)
            row.title = entry.title
            row.category = entry.category
            row.date = entry.date
            row.note = entry.note
            row.categoryID = entry.categoryID
            row.paymentMethodID = entry.paymentMethodID
            Self.setLocation(entry.location, on: row)
            row.eventID = entry.eventID
            row.budgetOverrideReason = entry.budgetOverrideReason
            row.updatedAt = .now
            row.deletedAt = nil
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Local acknowledgement only: do not advance the cloud financial timestamp.
    func markCategoryReviewed(_ entry: LedgerEntry) throws -> Bool {
        try setCategoryReviewed(entry, reviewed: true)
    }

    func reopenCategoryReview(_ entry: LedgerEntry) throws -> Bool {
        try setCategoryReviewed(entry, reviewed: false)
    }

    private func setCategoryReviewed(_ entry: LedgerEntry, reviewed: Bool) throws -> Bool {
        let context = container.viewContext
        let request = NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", entry.id as CVarArg)
        guard let row = try context.fetch(request).first,
              let categoryID = row.categoryID, categoryID == entry.categoryID,
              row.kind == entry.kind.rawValue, row.title == entry.title,
              let data = row.categorySuggestionData else { return false }
        var metadata = try CategoryHistoryMetadata.decode(data)
        guard var record = metadata.firstSave,
              record.source == nil else { return false }
        if reviewed {
            record.review = CategoryReviewAcknowledgement(categoryID: categoryID, kind: row.kind,
                                                          title: row.title, reviewedAt: .now)
        } else {
            guard let review = record.review,
                  review.matches(categoryID: categoryID, kind: row.kind, title: row.title),
                  review == entry.categorySuggestion?.review else { return false }
            record.review = nil
        }
        do {
            metadata.firstSave = record
            row.categorySuggestionData = try JSONEncoder().encode(metadata)
            try context.save()
            return true
        } catch {
            context.rollback()
            throw error
        }
    }

    func softDelete(id: UUID) throws {
        let context = container.viewContext
        let request = NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        do {
            if let row = try context.fetch(request).first {
                row.deletedAt = .now
                row.updatedAt = .now
                try context.save()
            }
        } catch {
            context.rollback()
            throw error
        }
    }

    func restoreDeleted(id: UUID) throws {
        let context = container.viewContext
        let request = NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        do {
            guard let row = try context.fetch(request).first, row.deletedAt != nil else { return }
            row.deletedAt = nil
            row.updatedAt = max(Date.now, row.updatedAt.addingTimeInterval(0.001))
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func syncEntry(id: UUID) throws -> CloudEntry? {
        let request = NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try container.viewContext.fetch(request).first.map(CloudEntry.init)
    }

    func allEntriesForSync() throws -> [CloudEntry] {
        let request = NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")
        return try container.viewContext.fetch(request).map(CloudEntry.init)
    }

    func applyRemote(_ entry: CloudEntry) throws {
        let context = container.viewContext
        let request = NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", entry.id as CVarArg)
        let old = try context.fetch(request).first
        if let old, old.updatedAt >= entry.updatedAt { return }
        do {
            let categories = try fetchCategories()
            let prior = old.map { row in
                CategorySelection(categoryID: row.categoryID,
                    name: categories.first { $0.id == row.categoryID }?.name ?? row.category, kind: row.kind)
            }
            var metadata = try CategoryHistoryMetadata.decode(old?.categorySuggestionData)
            let category: LedgerCategory
            if let existing = categories.first(where: { $0.id == entry.categoryID && $0.kind == entry.kind }) {
                category = existing
            } else if let existing = categories.first(where: { $0.kind == entry.kind && $0.name == entry.category }) {
                category = existing
            } else {
                category = LedgerCategory(id: entry.categoryID ?? UUID(), name: entry.category, kind: entry.kind,
                                           isSystem: false, isArchived: false, sortIndex: 100)
                try saveCategory(category)
            }
            if let prior, old?.deletedAt == nil, entry.deletedAt == nil {
                metadata.recordChange(from: prior,
                    to: .init(categoryID: category.id, name: category.name, kind: entry.kind.rawValue),
                    origin: .cloudUpdate)
            }
            let row = old ?? (NSEntityDescription.insertNewObject(forEntityName: "TransactionRecord", into: context) as! TransactionRecord)
            row.id = entry.id
            row.kind = entry.kind.rawValue
            row.amount = NSDecimalNumber(decimal: entry.amount)
            row.title = entry.title
            row.category = category.name
            row.date = entry.date
            row.note = entry.note
            row.createdAt = entry.createdAt
            row.updatedAt = entry.updatedAt
            row.deletedAt = entry.deletedAt
            row.categoryID = category.id
            row.categorySuggestionData = try JSONEncoder().encode(metadata)
            row.paymentMethodID = entry.paymentMethodID
            Self.setLocation(entry.location, on: row)
            row.eventID = entry.eventID
            row.budgetOverrideReason = entry.budgetOverrideReason
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func currentBudgetForSync() throws -> CloudBudget? {
        let request = NSFetchRequest<BudgetRecord>(entityName: "BudgetRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "month == %@", Self.monthStart() as NSDate)
        return try container.viewContext.fetch(request).first.map(CloudBudget.init)
    }

    func applyRemote(_ budget: CloudBudget) throws {
        let context = container.viewContext
        let request = NSFetchRequest<BudgetRecord>(entityName: "BudgetRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "month == %@", budget.month as NSDate)
        let old = try context.fetch(request).first
        if let old, old.updatedAt >= budget.updatedAt { return }
        let row = old ?? (NSEntityDescription.insertNewObject(forEntityName: "BudgetRecord", into: context) as! BudgetRecord)
        row.id = old?.id ?? UUID()
        row.month = budget.month
        row.amount = NSDecimalNumber(decimal: budget.amount)
        row.createdAt = old?.createdAt ?? budget.updatedAt
        row.updatedAt = budget.updatedAt
        try context.save()
    }

    func setCurrentBudget(_ amount: Decimal) throws {
        let context = container.viewContext
        let request = NSFetchRequest<BudgetRecord>(entityName: "BudgetRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "month == %@", Self.monthStart() as NSDate)
        do {
            let row = try context.fetch(request).first
                ?? (NSEntityDescription.insertNewObject(forEntityName: "BudgetRecord", into: context) as! BudgetRecord)
            if row.isInserted { row.id = UUID(); row.month = Self.monthStart(); row.createdAt = .now }
            row.amount = NSDecimalNumber(decimal: amount)
            row.updatedAt = .now
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func fetchCategoryBudgets(monthKey: String) throws -> [CategoryBudget] {
        let request = NSFetchRequest<CategoryBudgetRecord>(entityName: "CategoryBudgetRecord")
        request.predicate = NSPredicate(format: "monthKey == %@ AND amount > 0", monthKey)
        request.sortDescriptors = [NSSortDescriptor(key: "categoryName", ascending: true)]
        return try container.viewContext.fetch(request).map(Self.categoryBudget)
    }

    func allCategoryBudgetsForSync() throws -> [CategoryBudget] {
        let request = NSFetchRequest<CategoryBudgetRecord>(entityName: "CategoryBudgetRecord")
        return try container.viewContext.fetch(request).map(Self.categoryBudget)
    }

    func setCategoryBudget(_ budget: CategoryBudget) throws {
        guard budget.isValid else { throw LedgerDataError.invalidCategoryBudget }
        try upsertCategoryBudget(budget, onlyIfNewer: false)
    }

    func applyRemote(_ budget: CategoryBudget) throws {
        guard budget.isValid else { throw LedgerDataError.invalidCategoryBudget }
        if budget.amount > 0 && !((try? fetchCategories()) ?? []).contains(where: {
            $0.kind == .expense &&
            $0.name.compare(budget.categoryName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            let next = (try fetchCategories().filter { $0.kind == .expense }.map(\.sortIndex).max() ?? -1) + 1
            try saveCategory(LedgerCategory(id: UUID(), name: budget.categoryName, kind: .expense,
                                            isSystem: false, isArchived: false, sortIndex: next))
        }
        try upsertCategoryBudget(budget, onlyIfNewer: true)
    }

    private func upsertCategoryBudget(_ budget: CategoryBudget, onlyIfNewer: Bool) throws {
        let context = container.viewContext
        let request = NSFetchRequest<CategoryBudgetRecord>(entityName: "CategoryBudgetRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "key == %@", budget.id)
        do {
            let old = try context.fetch(request).first
            if onlyIfNewer, let old, old.updatedAt >= budget.updatedAt { return }
            let row = old ?? (NSEntityDescription.insertNewObject(
                forEntityName: "CategoryBudgetRecord", into: context) as! CategoryBudgetRecord)
            row.key = budget.id
            row.monthKey = budget.monthKey
            row.categoryName = budget.categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
            row.amount = NSDecimalNumber(decimal: budget.amount)
            row.updatedAt = budget.updatedAt
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func categoryBudget(_ row: CategoryBudgetRecord) -> CategoryBudget {
        CategoryBudget(monthKey: row.monthKey, categoryName: row.categoryName,
                       amount: row.amount.decimalValue, updatedAt: row.updatedAt)
    }

    func fetchLifeEvents() throws -> [LifeEvent] {
        let request = NSFetchRequest<LifeEventRecord>(entityName: "LifeEventRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: false)]
        return try container.viewContext.fetch(request).map(Self.lifeEvent)
    }

    func saveLifeEvent(_ event: LifeEvent) throws {
        guard event.isValid else { throw LedgerDataError.invalidLifeEvent }
        try upsertLifeEvent(event, onlyIfNewer: false)
    }

    func applyRemote(_ event: LifeEvent) throws {
        guard event.isValid else { throw LedgerDataError.invalidLifeEvent }
        try upsertLifeEvent(event, onlyIfNewer: true)
    }

    private func upsertLifeEvent(_ event: LifeEvent, onlyIfNewer: Bool) throws {
        let context = container.viewContext
        let request = NSFetchRequest<LifeEventRecord>(entityName: "LifeEventRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", event.id as CVarArg)
        do {
            let old = try context.fetch(request).first
            if onlyIfNewer, let old, old.updatedAt >= event.updatedAt { return }
            let row = old ?? (NSEntityDescription.insertNewObject(
                forEntityName: "LifeEventRecord", into: context) as! LifeEventRecord)
            row.id = event.id
            row.name = event.name.trimmingCharacters(in: .whitespacesAndNewlines)
            row.kind = event.kind.rawValue
            row.budget = NSDecimalNumber(decimal: event.budget)
            row.startDate = event.startDate
            row.endDate = event.endDate
            row.completedAt = event.completedAt
            row.completionSpent = event.completionSpent.map(NSDecimalNumber.init(decimal:))
            row.createdAt = old?.createdAt ?? event.createdAt
            row.updatedAt = event.updatedAt
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func lifeEvent(_ row: LifeEventRecord) -> LifeEvent {
        LifeEvent(id: row.id, name: row.name,
                  kind: LifeEventKind(rawValue: row.kind) ?? .other,
                  budget: row.budget.decimalValue,
                  startDate: row.startDate, endDate: row.endDate,
                  completedAt: row.completedAt,
                  completionSpent: row.completionSpent?.decimalValue,
                  createdAt: row.createdAt, updatedAt: row.updatedAt)
    }

    func fetchFriends() throws -> [LedgerFriend] {
        let request = NSFetchRequest<FriendRecord>(entityName: "FriendRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        return try container.viewContext.fetch(request).map {
            LedgerFriend(id: $0.id, name: $0.name, isArchived: $0.isArchived,
                         createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
    }

    func saveFriend(_ friend: LedgerFriend) throws {
        try upsertFriend(friend, onlyIfNewer: false)
    }

    func applyRemote(_ friend: LedgerFriend) throws {
        try upsertFriend(friend, onlyIfNewer: true)
    }

    private func upsertFriend(_ friend: LedgerFriend, onlyIfNewer: Bool) throws {
        guard friend.isValid else { throw LedgerDataError.invalidFriend }
        let context = container.viewContext
        let request = NSFetchRequest<FriendRecord>(entityName: "FriendRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", friend.id as CVarArg)
        do {
            let old = try context.fetch(request).first
            if onlyIfNewer, let old, old.updatedAt >= friend.updatedAt { return }
            if !onlyIfNewer, try fetchFriends().contains(where: {
                $0.id != friend.id && !$0.isArchived &&
                    $0.name.localizedCaseInsensitiveCompare(friend.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            }) { throw LedgerDataError.duplicateName }
            let row = old ?? (NSEntityDescription.insertNewObject(
                forEntityName: "FriendRecord", into: context) as! FriendRecord)
            row.id = friend.id
            row.name = friend.name.trimmingCharacters(in: .whitespacesAndNewlines)
            row.isArchived = friend.isArchived
            row.createdAt = old?.createdAt ?? friend.createdAt
            row.updatedAt = friend.updatedAt
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func fetchSplitBills() throws -> [SplitBill] {
        let request = NSFetchRequest<SplitBillRecord>(entityName: "SplitBillRecord")
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return try container.viewContext.fetch(request).map(splitBill)
    }

    func allSplitBillsForSync() throws -> [SplitBill] {
        let request = NSFetchRequest<SplitBillRecord>(entityName: "SplitBillRecord")
        return try container.viewContext.fetch(request).map(splitBill)
    }

    private func splitBill(_ row: SplitBillRecord) throws -> SplitBill {
        let request = NSFetchRequest<SplitShareRecord>(entityName: "SplitShareRecord")
        request.predicate = NSPredicate(format: "billID == %@", row.id as CVarArg)
        let shares = try container.viewContext.fetch(request).map {
            SplitShare(id: $0.id, friendID: $0.friendID,
                       amount: $0.amount.decimalValue, settledAt: $0.settledAt)
        }
        return SplitBill(id: row.id, entryID: row.entryID,
                         totalAmount: row.totalAmount.decimalValue, note: row.note,
                         shares: shares, createdAt: row.createdAt,
                         updatedAt: row.updatedAt, deletedAt: row.deletedAt)
    }

    func saveSplitBill(_ bill: SplitBill) throws {
        guard bill.isValid else { throw LedgerDataError.invalidSplit }
        guard try fetchSplitBills().allSatisfy({ $0.entryID != bill.entryID || $0.id == bill.id })
        else { throw LedgerDataError.invalidSplit }
        let entryRequest = NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")
        entryRequest.fetchLimit = 1
        entryRequest.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", bill.entryID as CVarArg)
        guard let entry = try container.viewContext.fetch(entryRequest).first,
              entry.kind == EntryKind.expense.rawValue,
              entry.amount.decimalValue == bill.totalAmount else { throw LedgerDataError.invalidSplit }
        let friendIDs = Set(try fetchFriends().map(\.id))
        guard bill.shares.compactMap(\.friendID).allSatisfy(friendIDs.contains) else {
            throw LedgerDataError.invalidSplit
        }
        try upsertSplitBill(bill, onlyIfNewer: false)
    }

    func deleteSplitBill(id: UUID) throws -> SplitBill? {
        guard var bill = try fetchSplitBills().first(where: { $0.id == id }) else { return nil }
        bill.deletedAt = .now
        bill.updatedAt = .now
        try upsertSplitBill(bill, onlyIfNewer: false)
        return bill
    }

    func applyRemote(_ bill: SplitBill) throws {
        guard bill.isValid else { throw LedgerDataError.invalidSplit }
        try upsertSplitBill(bill, onlyIfNewer: true)
    }

    private func upsertSplitBill(_ bill: SplitBill, onlyIfNewer: Bool) throws {
        let context = container.viewContext
        let request = NSFetchRequest<SplitBillRecord>(entityName: "SplitBillRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", bill.id as CVarArg)
        do {
            let old = try context.fetch(request).first
            if onlyIfNewer, let old, old.updatedAt >= bill.updatedAt { return }
            let row = old ?? (NSEntityDescription.insertNewObject(
                forEntityName: "SplitBillRecord", into: context) as! SplitBillRecord)
            row.id = bill.id
            row.entryID = bill.entryID
            row.totalAmount = NSDecimalNumber(decimal: bill.totalAmount)
            row.note = bill.note
            row.createdAt = old?.createdAt ?? bill.createdAt
            row.updatedAt = bill.updatedAt
            row.deletedAt = bill.deletedAt
            let sharesRequest = NSFetchRequest<SplitShareRecord>(entityName: "SplitShareRecord")
            sharesRequest.predicate = NSPredicate(format: "billID == %@", bill.id as CVarArg)
            for share in try context.fetch(sharesRequest) { context.delete(share) }
            for share in bill.shares {
                let item = NSEntityDescription.insertNewObject(
                    forEntityName: "SplitShareRecord", into: context) as! SplitShareRecord
                item.id = share.id
                item.billID = bill.id
                item.friendID = share.friendID
                item.amount = NSDecimalNumber(decimal: share.amount)
                item.settledAt = share.settledAt
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func monthStart() -> Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: .now)) ?? .now
    }

    func fetchCategories() throws -> [LedgerCategory] {
        let request = NSFetchRequest<CategoryRecord>(entityName: "CategoryRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "kind", ascending: true), NSSortDescriptor(key: "sortIndex", ascending: true)]
        return try container.viewContext.fetch(request).compactMap { row in
            guard let kind = EntryKind(rawValue: row.kind) else { return nil }
            return LedgerCategory(id: row.id, name: row.name, kind: kind, isSystem: row.isSystem,
                                  isArchived: row.isArchived, sortIndex: row.sortIndex)
        }
    }

    func saveCategory(_ category: LedgerCategory) throws {
        let context = container.viewContext
        let existing = try fetchCategories()
        if existing.contains(where: {
            $0.id != category.id && $0.kind == category.kind &&
            $0.name.compare(category.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) { throw LedgerDataError.duplicateName }
        let request = NSFetchRequest<CategoryRecord>(entityName: "CategoryRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", category.id as CVarArg)
        do {
            let row = try context.fetch(request).first
                ?? (NSEntityDescription.insertNewObject(forEntityName: "CategoryRecord", into: context) as! CategoryRecord)
            let previousName = row.isInserted ? nil : row.name
            row.id = category.id
            row.name = category.name
            row.kind = category.kind.rawValue
            row.isSystem = category.isSystem
            row.isArchived = category.isArchived
            row.sortIndex = category.sortIndex
            if let previousName, previousName != category.name {
                let entries = NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")
                entries.predicate = NSPredicate(format: "categoryID == %@", category.id as CVarArg)
                for entry in try context.fetch(entries) {
                    entry.category = category.name
                    entry.updatedAt = .now
                }
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func archiveCategory(id: UUID) throws {
        let context = container.viewContext
        let request = NSFetchRequest<CategoryRecord>(entityName: "CategoryRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        if let row = try context.fetch(request).first {
            row.isArchived = true
            try context.save()
        }
    }

    func fetchPaymentMethods() throws -> [LedgerPaymentMethod] {
        let request = NSFetchRequest<PaymentMethodRecord>(entityName: "PaymentMethodRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true)]
        return try container.viewContext.fetch(request).compactMap { row in
            guard let kind = PaymentKind(rawValue: row.kind) else { return nil }
            return LedgerPaymentMethod(id: row.id, name: row.name, kind: kind,
                                       lastFour: row.lastFour, isArchived: row.isArchived, sortIndex: row.sortIndex)
        }
    }

    func savePaymentMethod(_ method: LedgerPaymentMethod) throws {
        let context = container.viewContext
        let existing = try fetchPaymentMethods()
        if existing.contains(where: {
            $0.id != method.id &&
            $0.name.compare(method.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) { throw LedgerDataError.duplicateName }
        if let lastFour = method.lastFour, !lastFour.isEmpty,
           (lastFour.count != 4 || !lastFour.allSatisfy(\.isNumber)) {
            throw LedgerDataError.invalidLastFour
        }
        let request = NSFetchRequest<PaymentMethodRecord>(entityName: "PaymentMethodRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", method.id as CVarArg)
        do {
            let row = try context.fetch(request).first
                ?? (NSEntityDescription.insertNewObject(forEntityName: "PaymentMethodRecord", into: context) as! PaymentMethodRecord)
            row.id = method.id
            row.name = method.name
            row.kind = method.kind.rawValue
            row.lastFour = method.lastFour
            row.isArchived = method.isArchived
            row.sortIndex = method.sortIndex
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func archivePaymentMethod(id: UUID) throws {
        let context = container.viewContext
        let request = NSFetchRequest<PaymentMethodRecord>(entityName: "PaymentMethodRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        if let row = try context.fetch(request).first {
            row.isArchived = true
            try context.save()
        }
    }

    func fetchReminders() throws -> [LedgerReminder] {
        let request = NSFetchRequest<ReminderRecord>(entityName: "ReminderRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        return try container.viewContext.fetch(request).compactMap { row in
            guard let frequency = ReminderFrequency(rawValue: row.frequency) else { return nil }
            return LedgerReminder(id: row.id, title: row.title, amount: row.amount?.decimalValue,
                                  frequency: frequency, dayOfMonth: Int(row.dayOfMonth),
                                  weekday: Int(row.weekday), date: row.date,
                                  hour: Int(row.hour), minute: Int(row.minute), isPaused: row.isPaused)
        }
    }

    func saveReminder(_ reminder: LedgerReminder) throws { try saveReminder(reminder, acceptingPast: false) }

    func saveReminder(_ reminder: LedgerReminder, acceptingPast: Bool = false) throws {
        guard reminder.isValid || (acceptingPast && reminder.hasValidFields) else { throw LedgerDataError.invalidReminder }
        let context = container.viewContext
        let request = NSFetchRequest<ReminderRecord>(entityName: "ReminderRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", reminder.id as CVarArg)
        do {
            let row = try context.fetch(request).first
                ?? (NSEntityDescription.insertNewObject(forEntityName: "ReminderRecord", into: context) as! ReminderRecord)
            row.id = reminder.id
            row.title = reminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
            row.amount = reminder.amount.map(NSDecimalNumber.init(decimal:))
            row.frequency = reminder.frequency.rawValue
            row.dayOfMonth = Int16(reminder.dayOfMonth)
            row.weekday = Int16(reminder.weekday)
            row.date = reminder.date
            row.hour = Int16(reminder.hour)
            row.minute = Int16(reminder.minute)
            row.isPaused = reminder.isPaused
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func deleteReminder(id: UUID) throws {
        let context = container.viewContext
        let request = NSFetchRequest<ReminderRecord>(entityName: "ReminderRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        if let row = try context.fetch(request).first {
            context.delete(row)
            try context.save()
        }
    }

    func fetchPlaces() throws -> [LedgerPlace] {
        let request = NSFetchRequest<SavedPlaceRecord>(entityName: "SavedPlaceRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        return try container.viewContext.fetch(request).map {
            LedgerPlace(id: $0.id, name: $0.name, latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    func savePlace(_ place: LedgerPlace) throws {
        guard place.isValid else { throw LedgerDataError.invalidPlace }
        let context = container.viewContext
        let request = NSFetchRequest<SavedPlaceRecord>(entityName: "SavedPlaceRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", place.id as CVarArg)
        do {
            let row = try context.fetch(request).first ??
                (NSEntityDescription.insertNewObject(forEntityName: "SavedPlaceRecord", into: context) as! SavedPlaceRecord)
            row.id = place.id
            row.name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
            row.latitude = place.latitude
            row.longitude = place.longitude
            try context.save()
        } catch { context.rollback(); throw error }
    }

    func deletePlace(id: UUID) throws {
        let context = container.viewContext
        let request = NSFetchRequest<SavedPlaceRecord>(entityName: "SavedPlaceRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        if let row = try context.fetch(request).first { context.delete(row); try context.save() }
    }

    private static func location(from row: TransactionRecord) -> LedgerLocation? {
        guard let name = row.locationName,
              let latitude = row.locationLatitude?.doubleValue,
              let longitude = row.locationLongitude?.doubleValue else { return nil }
        let location = LedgerLocation(placeID: row.placeID, name: name,
                                      latitude: latitude, longitude: longitude)
        return location.isValid ? location : nil
    }

    private static func setLocation(_ location: LedgerLocation?, on row: TransactionRecord) {
        row.placeID = location?.placeID
        row.locationName = location?.name
        row.locationLatitude = location.map { NSNumber(value: $0.latitude) }
        row.locationLongitude = location.map { NSNumber(value: $0.longitude) }
    }

    func applyLibraryCategory(_ value: LedgerCategory) throws {
        let context = container.viewContext
        let request = NSFetchRequest<CategoryRecord>(entityName: "CategoryRecord")
        for row in try context.fetch(request) where row.id != value.id && row.kind == value.kind.rawValue && row.name.compare(value.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            let entries = NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")
            entries.predicate = NSPredicate(format: "categoryID == %@", row.id as CVarArg)
            for entry in try context.fetch(entries) { entry.categoryID = value.id }
            context.delete(row)
        }
        try saveCategory(value)
    }

    func applyLibraryPayment(_ value: LedgerPaymentMethod) throws {
        let context = container.viewContext
        for row in try context.fetch(NSFetchRequest<PaymentMethodRecord>(entityName: "PaymentMethodRecord")) where row.id != value.id && row.name.compare(value.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            let entries = NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")
            entries.predicate = NSPredicate(format: "paymentMethodID == %@", row.id as CVarArg)
            for entry in try context.fetch(entries) { entry.paymentMethodID = value.id }
            context.delete(row)
        }
        try savePaymentMethod(value)
    }

    private func seedDefaults() throws {
        let context = container.viewContext
        let categoryCount = try context.count(for: NSFetchRequest<CategoryRecord>(entityName: "CategoryRecord"))
        if categoryCount == 0 {
            for kind in EntryKind.allCases {
                for (index, name) in kind.defaultCategories.enumerated() {
                    let row = NSEntityDescription.insertNewObject(forEntityName: "CategoryRecord", into: context) as! CategoryRecord
                    row.id = StableLibraryID.make("category-\(kind.rawValue)-\(index)")
                    row.name = name
                    row.kind = kind.rawValue
                    row.isSystem = true
                    row.isArchived = false
                    row.sortIndex = Int16(index)
                }
            }
        }
        let methodCount = try context.count(for: NSFetchRequest<PaymentMethodRecord>(entityName: "PaymentMethodRecord"))
        if methodCount == 0 {
            for (index, kind) in [PaymentKind.cash, .debitCard, .creditCard].enumerated() {
                let row = NSEntityDescription.insertNewObject(forEntityName: "PaymentMethodRecord", into: context) as! PaymentMethodRecord
                row.id = StableLibraryID.make("payment-\(kind.rawValue)")
                row.name = kind.label
                row.kind = kind.rawValue
                row.isArchived = false
                row.sortIndex = Int16(index)
            }
        }
        // Upgrade old randomly generated built-ins and keep transaction links intact.
        for row in try context.fetch(NSFetchRequest<CategoryRecord>(entityName: "CategoryRecord")) where row.isSystem {
            let stable = StableLibraryID.make("category-\(row.kind)-\(row.sortIndex)")
            if row.id != stable {
                let request = NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")
                request.predicate = NSPredicate(format: "categoryID == %@", row.id as CVarArg)
                for entry in try context.fetch(request) { entry.categoryID = stable }
                row.id = stable
            }
        }
        for row in try context.fetch(NSFetchRequest<PaymentMethodRecord>(entityName: "PaymentMethodRecord")) {
            guard let kind = PaymentKind(rawValue: row.kind), row.name == kind.label else { continue }
            let stable = StableLibraryID.make("payment-\(kind.rawValue)")
            if row.id != stable {
                let request = NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")
                request.predicate = NSPredicate(format: "paymentMethodID == %@", row.id as CVarArg)
                for entry in try context.fetch(request) { entry.paymentMethodID = stable }
                row.id = stable
            }
        }
        if context.hasChanges { try context.save() }
    }

    private func linkLegacyCategories() throws {
        let context = container.viewContext
        let request = NSFetchRequest<TransactionRecord>(entityName: "TransactionRecord")
        request.predicate = NSPredicate(format: "categoryID == nil")
        let categories = try fetchCategories()
        for row in try context.fetch(request) {
            row.categoryID = categories.first {
                $0.kind.rawValue == row.kind &&
                $0.name.compare(row.category, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }?.id
        }
        if context.hasChanges { try context.save() }
    }
}
