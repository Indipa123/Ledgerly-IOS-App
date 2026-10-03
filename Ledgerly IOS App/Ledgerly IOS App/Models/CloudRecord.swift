import Foundation

struct CloudEntry {
    let id: UUID
    let kind: EntryKind
    let amount: Decimal
    let title: String
    let category: String
    let date: Date
    let note: String
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    init(_ row: TransactionRecord) {
        id = row.id
        kind = EntryKind(rawValue: row.kind) ?? .expense
        amount = row.amount.decimalValue
        title = row.title
        category = row.category
        date = row.date
        note = row.note
        createdAt = row.createdAt
        updatedAt = row.updatedAt
        deletedAt = row.deletedAt
    }

    init(id: UUID, kind: EntryKind, amount: Decimal, title: String, category: String,
         date: Date, note: String, createdAt: Date, updatedAt: Date, deletedAt: Date?) {
        self.id = id
        self.kind = kind
        self.amount = amount
        self.title = title
        self.category = category
        self.date = date
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

struct CloudBudget {
    let month: Date
    let amount: Decimal
    let updatedAt: Date

    init(_ row: BudgetRecord) {
        month = row.month
        amount = row.amount.decimalValue
        updatedAt = row.updatedAt
    }

    init(month: Date, amount: Decimal, updatedAt: Date) {
        self.month = month
        self.amount = amount
        self.updatedAt = updatedAt
    }
}
