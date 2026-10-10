import Foundation
import Testing
@testable import LedgerlyDomain

struct PlaceVisitTests {
    @Test func reconciliationDistinguishesInsideOutsideAndAbandoned() {
        let now = Date()
        let place = LedgerPlace(id: UUID(), name: "Shop", latitude: 7.0, longitude: 80.0)
        let open = PlaceVisit(id: UUID(), placeID: place.id, placeName: place.name,
                              enteredAt: now.addingTimeInterval(-60 * 60))
        let inside = PlaceVisitPolicy.reconciled(open, place: place, latitude: 7.0001,
                                                  longitude: 80, radius: 150, now: now)
        #expect(inside.isOpen)
        #expect(!PlaceVisitPolicy.shouldCreateVisit(openVisit: open, at: now))
        #expect(PlaceVisitPolicy.shouldCreateVisit(openVisit: nil, at: now))
        let outside = PlaceVisitPolicy.reconciled(open, place: place, latitude: 7.01,
                                                   longitude: 80, radius: 150, now: now)
        #expect(!outside.isOpen)
        #expect(outside.isReconciled)
        #expect(!outside.isAbandoned)
        let uncertain = PlaceVisitPolicy.reconciled(open, place: place, latitude: 7.01,
                                                     longitude: 80, radius: 150,
                                                     horizontalAccuracy: 2_000, now: now)
        #expect(uncertain.isOpen)
        let old = PlaceVisit(id: UUID(), placeID: place.id, placeName: place.name,
                             enteredAt: now.addingTimeInterval(-13 * 60 * 60))
        let abandoned = PlaceVisitPolicy.reconciled(old, place: place, latitude: 7,
                                                     longitude: 80, radius: 150, now: now)
        #expect(abandoned.isAbandoned)
        #expect(!abandoned.isOpen)
        #expect(PlaceVisitPolicy.shouldCreateVisit(openVisit: old, at: now))
        #expect(PlaceVisitPolicy.closed(outside, at: now) == outside)
    }

    @Test func priorityAllocatesScarceSlotsAndRetiresOldVisits() {
        let now = Date()
        let places = (0..<22).map {
            LedgerPlace(id: UUID(), name: String(format: "Place %02d", $0), latitude: 7, longitude: 80)
        }
        let frequent = places[21]
        let pinned = places[20]
        var visits: [PlaceVisit] = []
        for index in 0..<4 {
            let enteredAt = now.addingTimeInterval(-Double(index) * 86_400)
            let visit = PlaceVisit(id: UUID(), placeID: frequent.id, placeName: frequent.name,
                                   enteredAt: enteredAt, exitedAt: enteredAt.addingTimeInterval(1800))
            visits.append(visit)
        }
        let enabled = Set(places.map(\.id))
        let active = PlaceArrivalPolicy.activePlaces(places, enabledIDs: enabled,
                                                     visits: visits, pinnedIDs: [pinned.id], now: now)
        #expect(active.count == 20)
        #expect(active.first?.id == pinned.id)
        #expect(active[1].id == frequent.id)
        #expect(!active.contains(where: { $0.id == places[19].id }))
        let old = PlaceVisit(id: UUID(), placeID: frequent.id, placeName: frequent.name,
                             enteredAt: now.addingTimeInterval(-91 * 86_400))
        #expect(PlaceArrivalPolicy.priority(for: frequent.id, visits: [old],
                                            pinnedIDs: [], now: now) == 0)
    }
}
