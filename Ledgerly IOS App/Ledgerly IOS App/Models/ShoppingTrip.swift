import Foundation

struct ShoppingItem: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var unitPrice: Decimal
    var quantity: Int

    var total: Decimal { unitPrice * Decimal(quantity) }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && unitPrice > 0 && quantity > 0
    }
}

struct ShoppingTrip: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var cap: Decimal
    var categoryID: UUID
    var eventID: UUID?
    var startedAt: Date
    var items: [ShoppingItem]
    var quickAddAmount: Int? = nil
    var location: LedgerLocation? = nil

    var spent: Decimal { items.reduce(.zero) { $0 + $1.total } }
    var remaining: Decimal { cap - spent }
    var quickAddValue: Int { quickAddAmount ?? 100 }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        cap > 0 && items.allSatisfy(\.isValid)
    }

    var expenseNote: String {
        (["Shopping trip items:"] + items.map { item in
            "\(item.name) × \(item.quantity) — \(LKR.string(item.total))"
        }).joined(separator: "\n")
    }
}

struct ShoppingArrivalRule: Codable, Equatable {
    var cap: Decimal
    var categoryID: UUID

    func canStart(activeTrip: ShoppingTrip?, categoryAvailable: Bool) -> Bool {
        cap > 0 && activeTrip == nil && categoryAvailable
    }
}
