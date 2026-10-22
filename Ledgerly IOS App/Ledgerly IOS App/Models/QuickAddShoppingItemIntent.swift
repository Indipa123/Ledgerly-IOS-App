import AppIntents
import Foundation

struct QuickAddShoppingItemIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Add a shopping item"
    static var description = IntentDescription("Adds the trip's chosen quick amount as an item.")

    @Parameter(title: "Trip ID") var tripID: String

    init() {}
    init(tripID: String) { self.tripID = tripID }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        // LiveActivityIntent is executed in the containing app process.
        return .result()
        #else
        let owner = UserDefaults.standard.string(forKey: "ledgerly.shoppingOwner")
        let trips = ShoppingTripStore(accountID: owner)
        guard let trip = trips.activeTrip, trip.id.uuidString == tripID else { return .result() }
        _ = trips.addItem(name: "Quick add", unitPrice: Decimal(trip.quickAddValue), quantity: 1)
        return .result()
        #endif
    }
}
