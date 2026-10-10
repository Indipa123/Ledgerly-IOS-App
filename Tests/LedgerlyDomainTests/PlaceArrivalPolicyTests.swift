import Foundation
import Testing
@testable import LedgerlyDomain

struct PlaceArrivalPolicyTests {
    @Test func radiusAndRegionLimit() {
        #expect(PlaceArrivalPolicy.radius(5) == 50)
        #expect(PlaceArrivalPolicy.radius(250) == 250)
        #expect(PlaceArrivalPolicy.radius(900) == 500)
        let places = (0..<23).map {
            LedgerPlace(id: UUID(), name: "Place \($0)", latitude: 7, longitude: 80)
        }
        let active = PlaceArrivalPolicy.activePlaces(places, enabledIDs: Set(places.map(\.id)))
        #expect(active.count == 20)
        #expect(PlaceArrivalPolicy.activePlaces(places, enabledIDs: []).isEmpty)
    }

    @Test func arrivalCooldown() {
        let id = UUID()
        let now = Date()
        #expect(PlaceArrivalPolicy.shouldPrompt(placeID: id, now: now, lastPrompt: nil, entries: []))
        #expect(!PlaceArrivalPolicy.shouldPrompt(placeID: id, now: now,
                                                 lastPrompt: now.addingTimeInterval(-60), entries: []))
        #expect(PlaceArrivalPolicy.shouldPrompt(placeID: id, now: now,
                                                lastPrompt: now.addingTimeInterval(-31 * 60), entries: []))
        let expense = LedgerEntry(id: UUID(), kind: .expense, amount: 430,
                                  title: "Bus fare", category: "Transport",
                                  date: now.addingTimeInterval(-5 * 60), note: "",
                                  location: LedgerLocation(placeID: id, name: "Bus station",
                                                           latitude: 7, longitude: 80))
        #expect(!PlaceArrivalPolicy.shouldPrompt(placeID: id, now: now,
                                                 lastPrompt: nil, entries: [expense]))
        #expect(PlaceArrivalPolicy.shouldPrompt(placeID: UUID(), now: now,
                                                lastPrompt: nil, entries: [expense]))
    }
}
