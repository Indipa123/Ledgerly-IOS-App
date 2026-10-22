import Foundation

struct LedgerLocation: Codable, Hashable, Sendable {
    var placeID: UUID?
    var name: String
    var latitude: Double
    var longitude: Double

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        latitude.isFinite && longitude.isFinite &&
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

struct LedgerPlace: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var name: String
    var latitude: Double
    var longitude: Double

    var location: LedgerLocation {
        LedgerLocation(placeID: id, name: name, latitude: latitude, longitude: longitude)
    }

    var isValid: Bool { location.isValid }
}

struct SpendingMapPoint: Identifiable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let amount: Decimal
    let count: Int
}

struct PlaceSpendingPattern {
    let recordedCount: Int
    let typicalAmount: Decimal?
    let categoryID: UUID?
    let categoryExampleCount: Int

    static func analyze(entries: [LedgerEntry], place: LedgerPlace,
                        activeCategoryIDs: Set<UUID> = [],
                        excludedCategoryEntryIDs: Set<UUID> = [], asOf: Date = .now) -> Self {
        let history = entries.filter {
            guard $0.kind == .expense, let location = $0.location else { return false }
            return location.placeID == place.id && $0.date <= asOf &&
                abs(location.latitude - place.latitude) < 0.000001 &&
                abs(location.longitude - place.longitude) < 0.000001
        }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(12)

        let amounts = history.map(\.amount).sorted()
        let typical: Decimal?
        if amounts.count >= 3 {
            let middle = amounts.count / 2
            typical = amounts.count.isMultiple(of: 2)
                ? (amounts[middle - 1] + amounts[middle]) / 2
                : amounts[middle]
        } else {
            typical = nil
        }

        var counts: [UUID: Int] = [:]
        for entry in history {
            if !excludedCategoryEntryIDs.contains(entry.id),
               let id = entry.categoryID, activeCategoryIDs.contains(id) {
                counts[id, default: 0] += 1
            }
        }
        let winner = counts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key.uuidString < $1.key.uuidString
        }.first
        let reliable = winner.map { $0.value >= 2 && $0.value * 5 >= history.count * 4 } ?? false
        return .init(recordedCount: history.count, typicalAmount: typical,
                     categoryID: reliable ? winner?.key : nil,
                     categoryExampleCount: reliable ? winner?.value ?? 0 : 0)
    }
}

enum PlaceCalculations {
    /// Uses the same saved-ID and coordinate boundary as the spending map.
    /// Moving a pin must not move historical expenses to its new location.
    static func expenses(at place: LedgerPlace, in entries: [LedgerEntry]) -> [LedgerEntry] {
        entries.filter { entry in
            guard entry.kind == .expense, let location = entry.location, location.isValid else { return false }
            return location.placeID == place.id &&
                abs(location.latitude - place.latitude) < 0.000001 &&
                abs(location.longitude - place.longitude) < 0.000001
        }.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date
        }
    }

    static func mapPoints(places: [LedgerPlace], entries: [LedgerEntry]) -> [SpendingMapPoint] {
        var grouped: [String: SpendingMapPoint] = [:]
        for place in places {
            grouped[place.id.uuidString] = SpendingMapPoint(id: place.id.uuidString, name: place.name,
                latitude: place.latitude, longitude: place.longitude, amount: 0, count: 0)
        }
        for entry in entries where entry.kind == .expense {
            guard let location = entry.location, location.isValid else { continue }
            let saved = location.placeID.flatMap { id in places.first { $0.id == id } }
            let matchesSaved = saved.map {
                abs($0.latitude - location.latitude) < 0.000001 &&
                abs($0.longitude - location.longitude) < 0.000001
            } ?? false
            let key: String
            if matchesSaved, let saved { key = saved.id.uuidString }
            else { key = "\(location.name):\(location.latitude):\(location.longitude)" }
            let previous = grouped[key]
            grouped[key] = SpendingMapPoint(id: key, name: previous?.name ?? location.name,
                latitude: previous?.latitude ?? location.latitude,
                longitude: previous?.longitude ?? location.longitude,
                amount: (previous?.amount ?? 0) + entry.amount,
                count: (previous?.count ?? 0) + 1)
        }
        return grouped.values.sorted { $0.name < $1.name }
    }
}
