import Foundation
import Testing
@testable import LedgerlyDomain

struct ShoppingTripTests {
    @Test func totalsMultiplyQuantityAndKeepAnOverCapAmount() throws {
        let trip = ShoppingTrip(id: UUID(), name: "Weekly groceries", cap: 1_000,
                                categoryID: UUID(), eventID: nil, startedAt: .now,
                                items: [ShoppingItem(id: UUID(), name: "Rice", unitPrice: 350, quantity: 2),
                                        ShoppingItem(id: UUID(), name: "Milk", unitPrice: 325, quantity: 1)])
        #expect(trip.isValid)
        #expect(trip.spent == 1_025)
        #expect(trip.remaining == -25)
        #expect(trip.expenseNote.contains("Rice × 2"))
        #expect(trip.expenseNote.contains("Milk × 1"))
        let restored = try JSONDecoder().decode(ShoppingTrip.self, from: JSONEncoder().encode(trip))
        #expect(restored == trip)
        #expect(restored.quickAddValue == 100)
    }

    @Test func quickAddAmountSurvivesTripPersistence() throws {
        var trip = ShoppingTrip(id: UUID(), name: "Shop", cap: 1_000,
                                categoryID: UUID(), eventID: nil, startedAt: .now, items: [])
        trip.quickAddAmount = 250
        let restored = try JSONDecoder().decode(ShoppingTrip.self, from: JSONEncoder().encode(trip))
        #expect(restored.quickAddValue == 250)
    }

    @Test func invalidItemsCannotProduceASaveableTrip() {
        var trip = ShoppingTrip(id: UUID(), name: "", cap: 0, categoryID: UUID(),
                                eventID: nil, startedAt: .now, items: [])
        #expect(!trip.isValid)
        trip.name = "Shopping"
        trip.cap = 500
        trip.items = [ShoppingItem(id: UUID(), name: "Bread", unitPrice: 0, quantity: 1)]
        #expect(!trip.isValid)
        trip.items[0].unitPrice = 100
        #expect(trip.isValid)
    }

    @Test func arrivalRuleStartsOnlyWithAvailableCategoryAndNoActiveTrip() throws {
        let rule = ShoppingArrivalRule(cap: 2_000, categoryID: UUID())
        #expect(rule.canStart(activeTrip: nil, categoryAvailable: true))
        #expect(!rule.canStart(activeTrip: nil, categoryAvailable: false))
        let active = ShoppingTrip(id: UUID(), name: "Existing", cap: 500,
                                  categoryID: UUID(), eventID: nil, startedAt: .now, items: [])
        #expect(!rule.canStart(activeTrip: active, categoryAvailable: true))
        #expect(!ShoppingArrivalRule(cap: 0, categoryID: rule.categoryID)
            .canStart(activeTrip: nil, categoryAvailable: true))
        #expect(try JSONDecoder().decode(ShoppingArrivalRule.self,
                                        from: JSONEncoder().encode(rule)) == rule)
        let saved = [UUID(): rule]
        #expect(try JSONDecoder().decode([UUID: ShoppingArrivalRule].self,
                                        from: JSONEncoder().encode(saved)) == saved)
    }

    @Test func shoppingTripPreservesArrivalLocation() throws {
        let location = LedgerLocation(placeID: UUID(), name: "Keells", latitude: 6.9, longitude: 79.9)
        let trip = ShoppingTrip(id: UUID(), name: "Keells", cap: 2_000,
                                categoryID: UUID(), eventID: nil, startedAt: .now,
                                items: [], location: location)
        let restored = try JSONDecoder().decode(ShoppingTrip.self, from: JSONEncoder().encode(trip))
        #expect(restored.location == location)
    }
}
