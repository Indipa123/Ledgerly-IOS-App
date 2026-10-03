import Foundation
import CoreData

@objc(TransactionRecord)
final class TransactionRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var kind: Int16
    @NSManaged var amount: NSDecimalNumber
    @NSManaged var title: String
    @NSManaged var category: String
    @NSManaged var date: Date
    @NSManaged var note: String
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var deletedAt: Date?
    @NSManaged var categoryID: UUID?
    @NSManaged var paymentMethodID: UUID?
}

@objc(BudgetRecord)
final class BudgetRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var month: Date
    @NSManaged var amount: NSDecimalNumber
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
}

@objc(CategoryRecord)
final class CategoryRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var kind: Int16
    @NSManaged var isSystem: Bool
    @NSManaged var isArchived: Bool
    @NSManaged var sortIndex: Int16
}

@objc(PaymentMethodRecord)
final class PaymentMethodRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var kind: Int16
    @NSManaged var lastFour: String?
    @NSManaged var isArchived: Bool
    @NSManaged var sortIndex: Int16
}


enum CoreDataModel {
    static func make() -> NSManagedObjectModel {
        func field(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let item = NSAttributeDescription()
            item.name = name
            item.attributeType = type
            item.isOptional = optional
            return item
        }
        let transaction = NSEntityDescription()
        transaction.name = "TransactionRecord"
        transaction.managedObjectClassName = NSStringFromClass(TransactionRecord.self)
        transaction.properties = [
            field("id", .UUIDAttributeType), field("kind", .integer16AttributeType),
            field("amount", .decimalAttributeType), field("title", .stringAttributeType),
            field("category", .stringAttributeType), field("date", .dateAttributeType),
            field("note", .stringAttributeType), field("createdAt", .dateAttributeType),
            field("updatedAt", .dateAttributeType), field("deletedAt", .dateAttributeType, optional: true),
            field("categoryID", .UUIDAttributeType, optional: true),
            field("paymentMethodID", .UUIDAttributeType, optional: true)
        ]
        transaction.uniquenessConstraints = [["id"]]
        let budget = NSEntityDescription()
        budget.name = "BudgetRecord"
        budget.managedObjectClassName = NSStringFromClass(BudgetRecord.self)
        budget.properties = [
            field("id", .UUIDAttributeType), field("month", .dateAttributeType),
            field("amount", .decimalAttributeType), field("createdAt", .dateAttributeType),
            field("updatedAt", .dateAttributeType)
        ]
        budget.uniquenessConstraints = [["month"]]
        let category = NSEntityDescription()
        category.name = "CategoryRecord"
        category.managedObjectClassName = NSStringFromClass(CategoryRecord.self)
        category.properties = [
            field("id", .UUIDAttributeType), field("name", .stringAttributeType),
            field("kind", .integer16AttributeType), field("isSystem", .booleanAttributeType),
            field("isArchived", .booleanAttributeType), field("sortIndex", .integer16AttributeType)
        ]
        category.uniquenessConstraints = [["id"]]
        let paymentMethod = NSEntityDescription()
        paymentMethod.name = "PaymentMethodRecord"
        paymentMethod.managedObjectClassName = NSStringFromClass(PaymentMethodRecord.self)
        paymentMethod.properties = [
            field("id", .UUIDAttributeType), field("name", .stringAttributeType),
            field("kind", .integer16AttributeType), field("lastFour", .stringAttributeType, optional: true),
            field("isArchived", .booleanAttributeType), field("sortIndex", .integer16AttributeType)
        ]
        paymentMethod.uniquenessConstraints = [["id"]]
        let model = NSManagedObjectModel()
        model.entities = [transaction, budget, category, paymentMethod]
        return model
    }
}
