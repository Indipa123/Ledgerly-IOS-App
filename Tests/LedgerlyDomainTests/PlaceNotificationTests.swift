import Foundation
import Testing
@testable import LedgerlyDomain

struct PlaceNotificationTests {
    private let arrival = Date(timeIntervalSince1970: 1_000_000)

    @Test func departuresWithoutExpensesStillOfferARecordReminder() throws {
        let visit = PlaceVisit(id: UUID(), placeID: UUID(), placeName: "Shop",
            enteredAt: arrival, exitedAt: arrival.addingTimeInterval(600))
        #expect(PlaceDepartureNotice.make(for: visit, entries: [], enabled: true) == .unrecorded)
        let income = LedgerEntry(id: UUID(), kind: .income, amount: 500, title: "Income",
            category: "Other", date: arrival.addingTimeInterval(120), note: "",
            location: .init(placeID: visit.placeID, name: "Shop", latitude: 7, longitude: 80))
        #expect(PlaceDepartureNotice.make(for: visit, entries: [income], enabled: true) == .unrecorded)
    }

    @Test func realDepartureSummarizesOnlyExpensesDuringThisVisit() throws {
        let visit = PlaceVisit(id: UUID(), placeID: UUID(), placeName: "Shop",
            enteredAt: arrival, exitedAt: arrival.addingTimeInterval(600))
        func entry(_ amount: Decimal, placeID: UUID, at date: Date) -> LedgerEntry {
            .init(id: UUID(), kind: .expense, amount: amount, title: "Purchase", category: "Other",
                date: date, note: "", location: .init(placeID: placeID, name: "Shop", latitude: 7, longitude: 80))
        }
        let purchase = entry(200, placeID: visit.placeID, at: arrival.addingTimeInterval(300))
        let other = entry(900, placeID: UUID(), at: arrival.addingTimeInterval(300))
        let earlier = entry(800, placeID: visit.placeID, at: arrival.addingTimeInterval(-1))
        let notice = PlaceDepartureNotice.make(for: visit, entries: [purchase, other, earlier], enabled: true)
        #expect(notice == .recorded(.init(count: 1, total: 200, latestEntryID: purchase.id)))
    }

    @Test func disabledOpenEstimatedAndAbandonedVisitsDoNotNotify() {
        let open = PlaceVisit(id: UUID(), placeID: UUID(), placeName: "Shop", enteredAt: arrival)
        let closed = PlaceVisitPolicy.closed(open, at: arrival.addingTimeInterval(600))
        #expect(PlaceDepartureNotice.make(for: open, entries: [], enabled: true) == nil)
        #expect(PlaceDepartureNotice.make(for: closed, entries: [], enabled: false) == nil)
        for (reconciled, abandoned) in [(true, false), (false, true), (true, true)] {
            let stale = PlaceVisitPolicy.closed(open, at: arrival.addingTimeInterval(600),
                reconciled: reconciled, abandoned: abandoned)
            #expect(PlaceDepartureNotice.make(for: stale, entries: [], enabled: true) == nil)
        }
    }

    @Test func notificationChoicesPersistWithoutChangingOtherPlacePreferences() throws {
        let defaults = PlaceNotificationPreferences()
        #expect(defaults.departureEnabled)
        #expect(defaults.arrivalSound == .chime && defaults.departureSound == .chime)
        let selected = PlaceNotificationPreferences(departureEnabled: false,
            arrivalSound: .silent, departureSound: .system)
        let restored = try JSONDecoder().decode(PlaceNotificationPreferences.self,
            from: JSONEncoder().encode(selected))
        #expect(restored == selected)
        #expect(restored.sound(for: .arrival) == .silent)
        #expect(restored.sound(for: .departure) == .system)
    }

    @Test func originalChimesAreDistinctShortLinearPCMWaves() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Ledgerly IOS App/Ledgerly IOS App/Assets/NotificationSounds")
        var files: [Data] = []
        for kind in PlaceAlertKind.allCases {
            let name = try #require(PlaceAlertSound.chime.filename(for: kind))
            let bytes = try Data(contentsOf: root.appendingPathComponent(name))
            #expect(String(data: bytes.prefix(4), encoding: .ascii) == "RIFF")
            #expect(String(data: bytes.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
            // 44-byte PCM header: mono, 16-bit, 44.1 kHz; at least 0.5s and under 30s.
            #expect(Array(bytes[20..<24]) == [1, 0, 1, 0])
            #expect(Array(bytes[24..<28]) == [68, 172, 0, 0])
            #expect(Array(bytes[34..<36]) == [16, 0])
            #expect(bytes.count > 44_144 && bytes.count < 2_646_044)
            files.append(bytes)
        }
        #expect(files[0] != files[1])
        #expect(PlaceAlertSound.system.filename(for: .arrival) == nil)
        #expect(PlaceAlertSound.silent.filename(for: .departure) == nil)
    }
}
