import Foundation

enum EntryKind: Int16, CaseIterable, Identifiable {
    case expense = 0, income = 1
    var id: Int16 { rawValue }
    var label: String { self == .expense ? "Expense" : "Income" }
    var defaultCategories: [String] {
        self == .expense
        ? ["Food & Drink", "Groceries", "Transport", "Bills & Utilities", "Rent", "Education", "Health", "Shopping", "Entertainment", "Personal Care", "Gifts & Donations", "Other"]
        : ["Salary", "Freelance", "Business", "Bonus", "Gift", "Other"]
    }
}

struct LedgerEntry: Identifiable {
    let id: UUID
    let kind: EntryKind
    let amount: Decimal
    let title: String
    let category: String
    let date: Date
    let note: String
    var categoryID: UUID? = nil
    var paymentMethodID: UUID? = nil

    var displayTitle: String {
        let description = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? category : description
    }
}

struct LedgerCategory: Identifiable, Hashable {
    let id: UUID
    var name: String
    let kind: EntryKind
    let isSystem: Bool
    var isArchived: Bool
    var sortIndex: Int16
}

enum PaymentKind: Int16, CaseIterable, Identifiable {
    case cash = 0, debitCard, creditCard, mobileWallet, bankTransfer
    var id: Int16 { rawValue }
    var label: String {
        switch self {
        case .cash: "Cash"
        case .debitCard: "Debit card"
        case .creditCard: "Credit card"
        case .mobileWallet: "Mobile wallet"
        case .bankTransfer: "Bank transfer"
        }
    }
}

struct LedgerPaymentMethod: Identifiable, Hashable {
    let id: UUID
    var name: String
    var kind: PaymentKind
    var lastFour: String?
    var isArchived: Bool
    var sortIndex: Int16
}

enum LKR {
    static func string(_ value: Decimal) -> String {
        value.formatted(.currency(code: "LKR").locale(Locale(identifier: "en_LK")))
    }
}
