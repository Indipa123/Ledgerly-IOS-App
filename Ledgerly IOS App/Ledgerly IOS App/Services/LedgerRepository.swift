import Foundation
import CoreData

@MainActor
protocol LedgerRepository {
    func fetchEntries() throws -> [LedgerEntry]
    func fetchCurrentBudget() throws -> Decimal
    func upsert(_ entry: LedgerEntry) throws
    func softDelete(id: UUID) throws
    func setCurrentBudget(_ amount: Decimal) throws
    func fetchCategories() throws -> [LedgerCategory]
    func saveCategory(_ category: LedgerCategory) throws
    func archiveCategory(id: UUID) throws
    func fetchPaymentMethods() throws -> [LedgerPaymentMethod]
    func savePaymentMethod(_ method: LedgerPaymentMethod) throws
    func archivePaymentMethod(id: UUID) throws
}

enum LedgerDataError: LocalizedError {
    case duplicateName, missingCategory, wrongCategoryKind, invalidLastFour
    var errorDescription: String? {
        switch self {
        case .duplicateName: "That name is already in use."
        case .missingCategory: "Choose an active category."
        case .wrongCategoryKind: "The category must match the transaction type."
        case .invalidLastFour: "Enter exactly four digits for the card label."
        }
    }
}

@MainActor
final class CoreDataLedgerRepository: LedgerRepository {
    private let container: NSPersistentContainer

    init(inMemory: Bool = false, accountID: String? = nil) {
        container = NSPersistentContainer(name: "Ledgerly", managedObjectModel: CoreDataModel.make())
        container.persistentStoreDescriptions.forEach {
            $0.shouldMigrateStoreAutomatically = true
            $0.shouldInferMappingModelAutomatically = true
            if inMemory { $0.type = NSInMemoryStoreType }
            else if let accountID {
                let safeID = Data(accountID.utf8).base64EncodedString()
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "+", with: "-")
                let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                $0.url = folder.appendingPathComponent("Ledgerly-account-\(safeID).sqlite")
            }
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
            return LedgerEntry(id: row.id, kind: kind, amount: row.amount.decimalValue,
                               title: row.title, category: row.categoryID.flatMap { categoryNames[$0] } ?? row.category,
                               date: row.date, note: row.note,
                               categoryID: row.categoryID, paymentMethodID: row.paymentMethodID)
        }
    }

    func fetchCurrentBudget() throws -> Decimal {
        let request = NSFetchRequest<BudgetRecord>(entityName: "BudgetRecord")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "month == %@", Self.monthStart() as NSDate)
        return try container.viewContext.fetch(request).first?.amount.decimalValue ?? 0
    }

    func upsert(_ entry: LedgerEntry) throws {
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
            if row.isInserted { row.id = entry.id; row.createdAt = .now }
            row.kind = entry.kind.rawValue
            row.amount = NSDecimalNumber(decimal: entry.amount)
            row.title = entry.title
            row.category = entry.category
            row.date = entry.date
            row.note = entry.note
            row.categoryID = entry.categoryID
            row.paymentMethodID = entry.paymentMethodID
            row.updatedAt = .now
            row.deletedAt = nil
            try context.save()
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
        let row = old ?? (NSEntityDescription.insertNewObject(forEntityName: "TransactionRecord", into: context) as! TransactionRecord)
        row.id = entry.id
        row.kind = entry.kind.rawValue
        row.amount = NSDecimalNumber(decimal: entry.amount)
        row.title = entry.title
        row.category = entry.category
        row.date = entry.date
        row.note = entry.note
        row.createdAt = entry.createdAt
        row.updatedAt = entry.updatedAt
        row.deletedAt = entry.deletedAt
        if let category = try fetchCategories().first(where: {
            $0.kind == entry.kind && $0.name == entry.category
        }) {
            row.categoryID = category.id
        } else {
            let category = LedgerCategory(id: UUID(), name: entry.category, kind: entry.kind,
                                          isSystem: false, isArchived: false, sortIndex: 100)
            try saveCategory(category)
            row.categoryID = category.id
        }
        row.paymentMethodID = nil
        try context.save()
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
            row.id = category.id
            row.name = category.name
            row.kind = category.kind.rawValue
            row.isSystem = category.isSystem
            row.isArchived = category.isArchived
            row.sortIndex = category.sortIndex
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

    private func seedDefaults() throws {
        let context = container.viewContext
        let categoryCount = try context.count(for: NSFetchRequest<CategoryRecord>(entityName: "CategoryRecord"))
        if categoryCount == 0 {
            for kind in EntryKind.allCases {
                for (index, name) in kind.defaultCategories.enumerated() {
                    let row = NSEntityDescription.insertNewObject(forEntityName: "CategoryRecord", into: context) as! CategoryRecord
                    row.id = UUID()
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
                row.id = UUID()
                row.name = kind.label
                row.kind = kind.rawValue
                row.isArchived = false
                row.sortIndex = Int16(index)
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
