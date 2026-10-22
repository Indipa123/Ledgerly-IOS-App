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
    @NSManaged var placeID: UUID?
    @NSManaged var locationName: String?
    @NSManaged var locationLatitude: NSNumber?
    @NSManaged var locationLongitude: NSNumber?
    @NSManaged var eventID: UUID?
    @NSManaged var budgetOverrideReason: String?
    @NSManaged var categorySuggestionData: Data?
}

@objc(LifeEventRecord)
final class LifeEventRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var kind: String
    @NSManaged var budget: NSDecimalNumber
    @NSManaged var startDate: Date
    @NSManaged var endDate: Date
    @NSManaged var completedAt: Date?
    @NSManaged var completionSpent: NSDecimalNumber?
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
}

@objc(FriendRecord)
final class FriendRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var isArchived: Bool
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
}

@objc(SplitBillRecord)
final class SplitBillRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var entryID: UUID
    @NSManaged var totalAmount: NSDecimalNumber
    @NSManaged var note: String
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var deletedAt: Date?
}

@objc(SplitShareRecord)
final class SplitShareRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var billID: UUID
    @NSManaged var friendID: UUID?
    @NSManaged var amount: NSDecimalNumber
    @NSManaged var settledAt: Date?
}

@objc(BudgetRecord)
final class BudgetRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var month: Date
    @NSManaged var amount: NSDecimalNumber
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
}

@objc(CategoryBudgetRecord)
final class CategoryBudgetRecord: NSManagedObject {
    @NSManaged var key: String
    @NSManaged var monthKey: String
    @NSManaged var categoryName: String
    @NSManaged var amount: NSDecimalNumber
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

@objc(ReminderRecord)
final class ReminderRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var amount: NSDecimalNumber?
    @NSManaged var frequency: Int16
    @NSManaged var dayOfMonth: Int16
    @NSManaged var weekday: Int16
    @NSManaged var date: Date
    @NSManaged var hour: Int16
    @NSManaged var minute: Int16
    @NSManaged var isPaused: Bool
}

@objc(SavedPlaceRecord)
final class SavedPlaceRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var latitude: Double
    @NSManaged var longitude: Double
}


enum CoreDataModel {
    static func make(includeSuggestionHistory: Bool = true) -> NSManagedObjectModel {
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
            field("paymentMethodID", .UUIDAttributeType, optional: true),
            field("placeID", .UUIDAttributeType, optional: true),
            field("locationName", .stringAttributeType, optional: true),
            field("locationLatitude", .doubleAttributeType, optional: true),
            field("locationLongitude", .doubleAttributeType, optional: true),
            field("eventID", .UUIDAttributeType, optional: true),
            field("budgetOverrideReason", .stringAttributeType, optional: true)
        ]
        if includeSuggestionHistory {
            transaction.properties.append(field("categorySuggestionData", .binaryDataAttributeType, optional: true))
        }
        transaction.uniquenessConstraints = [["id"]]
        let lifeEvent = NSEntityDescription()
        lifeEvent.name = "LifeEventRecord"
        lifeEvent.managedObjectClassName = NSStringFromClass(LifeEventRecord.self)
        lifeEvent.properties = [
            field("id", .UUIDAttributeType), field("name", .stringAttributeType),
            field("kind", .stringAttributeType), field("budget", .decimalAttributeType),
            field("startDate", .dateAttributeType), field("endDate", .dateAttributeType),
            field("completedAt", .dateAttributeType, optional: true),
            field("completionSpent", .decimalAttributeType, optional: true),
            field("createdAt", .dateAttributeType), field("updatedAt", .dateAttributeType)
        ]
        lifeEvent.uniquenessConstraints = [["id"]]
        let friend = NSEntityDescription()
        friend.name = "FriendRecord"
        friend.managedObjectClassName = NSStringFromClass(FriendRecord.self)
        friend.properties = [
            field("id", .UUIDAttributeType), field("name", .stringAttributeType),
            field("isArchived", .booleanAttributeType), field("createdAt", .dateAttributeType),
            field("updatedAt", .dateAttributeType)
        ]
        friend.uniquenessConstraints = [["id"]]
        let splitBill = NSEntityDescription()
        splitBill.name = "SplitBillRecord"
        splitBill.managedObjectClassName = NSStringFromClass(SplitBillRecord.self)
        splitBill.properties = [
            field("id", .UUIDAttributeType), field("entryID", .UUIDAttributeType),
            field("totalAmount", .decimalAttributeType), field("note", .stringAttributeType),
            field("createdAt", .dateAttributeType), field("updatedAt", .dateAttributeType),
            field("deletedAt", .dateAttributeType, optional: true)
        ]
        splitBill.uniquenessConstraints = [["id"]]
        let splitShare = NSEntityDescription()
        splitShare.name = "SplitShareRecord"
        splitShare.managedObjectClassName = NSStringFromClass(SplitShareRecord.self)
        splitShare.properties = [
            field("id", .UUIDAttributeType), field("billID", .UUIDAttributeType),
            field("friendID", .UUIDAttributeType, optional: true),
            field("amount", .decimalAttributeType),
            field("settledAt", .dateAttributeType, optional: true)
        ]
        splitShare.uniquenessConstraints = [["id"]]
        let budget = NSEntityDescription()
        budget.name = "BudgetRecord"
        budget.managedObjectClassName = NSStringFromClass(BudgetRecord.self)
        budget.properties = [
            field("id", .UUIDAttributeType), field("month", .dateAttributeType),
            field("amount", .decimalAttributeType), field("createdAt", .dateAttributeType),
            field("updatedAt", .dateAttributeType)
        ]
        budget.uniquenessConstraints = [["month"]]
        let categoryBudget = NSEntityDescription()
        categoryBudget.name = "CategoryBudgetRecord"
        categoryBudget.managedObjectClassName = NSStringFromClass(CategoryBudgetRecord.self)
        categoryBudget.properties = [
            field("key", .stringAttributeType), field("monthKey", .stringAttributeType),
            field("categoryName", .stringAttributeType), field("amount", .decimalAttributeType),
            field("updatedAt", .dateAttributeType)
        ]
        categoryBudget.uniquenessConstraints = [["key"]]
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
        let reminder = NSEntityDescription()
        reminder.name = "ReminderRecord"
        reminder.managedObjectClassName = NSStringFromClass(ReminderRecord.self)
        reminder.properties = [
            field("id", .UUIDAttributeType), field("title", .stringAttributeType),
            field("amount", .decimalAttributeType, optional: true),
            field("frequency", .integer16AttributeType),
            field("dayOfMonth", .integer16AttributeType), field("weekday", .integer16AttributeType),
            field("date", .dateAttributeType), field("hour", .integer16AttributeType),
            field("minute", .integer16AttributeType), field("isPaused", .booleanAttributeType)
        ]
        reminder.uniquenessConstraints = [["id"]]
        let place = NSEntityDescription()
        place.name = "SavedPlaceRecord"
        place.managedObjectClassName = NSStringFromClass(SavedPlaceRecord.self)
        place.properties = [field("id", .UUIDAttributeType), field("name", .stringAttributeType),
                            field("latitude", .doubleAttributeType), field("longitude", .doubleAttributeType)]
        place.uniquenessConstraints = [["id"]]
        let model = NSManagedObjectModel()
        model.entities = [transaction, lifeEvent, friend, splitBill, splitShare,
                          budget, categoryBudget, category, paymentMethod, reminder, place]
        return model
    }
}
