import Foundation
import Testing
@testable import LedgerlyDomain

struct PlaceVisitTests {
    @Test func repeatedInsideChecksKeepOneVisitAndAnOutsideCheckAllowsReentry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let place = LedgerPlace(id: UUID(), name: "Shop", latitude: 7, longitude: 80)
        var visits: [PlaceVisit] = []
        // Initial inside-state and the boundary callback can both report the same arrival.
        for seconds in [0.0, 1.0, 60.0] {
            let at = now.addingTimeInterval(seconds)
            let open = visits.first { $0.placeID == place.id && $0.isOpen }
            if PlaceVisitPolicy.shouldCreateVisit(openVisit: open, at: at) {
                visits.append(.init(id: UUID(), placeID: place.id, placeName: place.name, enteredAt: at))
            }
        }
        #expect(visits.count == 1)
        let outside = PlaceVisitPolicy.closed(visits[0], at: now.addingTimeInterval(120), reconciled: true)
        #expect(outside.isReconciled)
        #expect(PlaceVisitPolicy.spendingSummary(for: outside, entries: []) == nil)
        visits[0] = outside
        #expect(PlaceVisitPolicy.shouldCreateVisit(openVisit: visits.first { $0.isOpen },
                                                  at: now.addingTimeInterval(180)))
    }

    @Test func departureSummaryIncludesOnlyExpensesRecordedAtThatPlaceDuringVisit() throws {
        let placeID = UUID()
        let otherPlaceID = UUID()
        let arrival = Date(timeIntervalSince1970: 1_000_000)
        let departure = arrival.addingTimeInterval(3_600)
        let visit = PlaceVisit(id: UUID(), placeID: placeID, placeName: "Shop",
                               enteredAt: arrival, exitedAt: departure)
        func entry(_ amount: Decimal, _ kind: EntryKind, _ date: Date,
                   _ savedPlaceID: UUID?) -> LedgerEntry {
            LedgerEntry(id: UUID(), kind: kind, amount: amount, title: "Purchase",
                        category: "Other", date: date, note: "",
                        location: LedgerLocation(placeID: savedPlaceID, name: "Shop",
                                                 latitude: 7, longitude: 80))
        }
        let first = entry(125, .expense, arrival, placeID)
        let latest = entry(75, .expense, departure, placeID)
        let unrelated = [
            entry(900, .income, arrival.addingTimeInterval(30), placeID),
            entry(800, .expense, arrival.addingTimeInterval(30), otherPlaceID),
            entry(700, .expense, arrival.addingTimeInterval(-1), placeID),
            entry(600, .expense, departure.addingTimeInterval(1), placeID)
        ]
        #expect(PlaceVisitPolicy.spendingSummary(for: visit, entries: unrelated) == nil)
        let summary = try #require(PlaceVisitPolicy.spendingSummary(
            for: visit, entries: unrelated + [first, latest]))
        #expect(summary.count == 2)
        #expect(summary.total == 200)
        #expect(summary.latestEntryID == latest.id)
        #expect(PlaceVisitPolicy.spendingSummary(
            for: PlaceVisit(id: visit.id, placeID: placeID, placeName: "Shop",
                            enteredAt: arrival), entries: [first]) == nil)
        #expect(PlaceVisitPolicy.spendingSummary(
            for: PlaceVisit(id: visit.id, placeID: placeID, placeName: "Shop",
                            enteredAt: arrival, exitedAt: departure, isAbandoned: true),
            entries: [first]) == nil)
    }

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
