import Foundation

struct PlaceVisit: Identifiable, Codable, Equatable {
    let id: UUID
    let placeID: UUID
    let placeName: String
    let enteredAt: Date
    var exitedAt: Date?
    var isReconciled = false
    var isAbandoned = false

    var isOpen: Bool { exitedAt == nil }
}

struct PlaceVisitSpendingSummary: Equatable {
    let count: Int
    let total: Decimal
    let latestEntryID: UUID
}

enum PlaceVisitPolicy {
    static let abandonedAfter: TimeInterval = 12 * 60 * 60

    static func spendingSummary(for visit: PlaceVisit,
                                entries: [LedgerEntry]) -> PlaceVisitSpendingSummary? {
        guard let exitedAt = visit.exitedAt, !visit.isAbandoned else { return nil }
        let recorded = entries.filter { entry in
            entry.kind == .expense && entry.location?.placeID == visit.placeID &&
                entry.date >= visit.enteredAt && entry.date <= exitedAt
        }
        guard let latest = recorded.max(by: {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }) else { return nil }
        return PlaceVisitSpendingSummary(
            count: recorded.count,
            total: recorded.reduce(Decimal.zero) { $0 + $1.amount },
            latestEntryID: latest.id
        )
    }

    static func shouldCreateVisit(openVisit: PlaceVisit?, at now: Date) -> Bool {
        guard let openVisit else { return true }
        return now.timeIntervalSince(openVisit.enteredAt) >= abandonedAfter
    }

    static func closed(_ visit: PlaceVisit, at date: Date,
                       reconciled: Bool = false, abandoned: Bool = false) -> PlaceVisit {
        guard visit.isOpen else { return visit }
        var result = visit
        result.exitedAt = max(date, visit.enteredAt)
        result.isReconciled = reconciled
        result.isAbandoned = abandoned
        return result
    }

    static func reconciled(_ visit: PlaceVisit, place: LedgerPlace?,
                           latitude: Double, longitude: Double, radius: Double,
                           horizontalAccuracy: Double = 0,
                           now: Date) -> PlaceVisit {
        guard visit.isOpen else { return visit }
        if now.timeIntervalSince(visit.enteredAt) >= abandonedAfter {
            return closed(visit, at: now, reconciled: true, abandoned: true)
        }
        guard let place else { return closed(visit, at: now, reconciled: true) }
        return distanceMeters(from: latitude, longitude: longitude,
                              to: place.latitude, longitude: place.longitude) <=
                radius + max(0, horizontalAccuracy)
            ? visit : closed(visit, at: now, reconciled: true)
    }

    static func distanceMeters(from latitude: Double, longitude: Double,
                               to otherLatitude: Double, longitude otherLongitude: Double) -> Double {
        let rad = Double.pi / 180
        let deltaLatitude = (otherLatitude - latitude) * rad
        let deltaLongitude = (otherLongitude - longitude) * rad
        let a = pow(sin(deltaLatitude / 2), 2) +
            cos(latitude * rad) * cos(otherLatitude * rad) * pow(sin(deltaLongitude / 2), 2)
        return 6_371_000 * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}
