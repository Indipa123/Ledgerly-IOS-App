import Foundation

struct LedgerLocation: Hashable, Sendable {
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

struct LedgerPlace: Identifiable, Hashable, Sendable {
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

enum PlaceCalculations {
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
