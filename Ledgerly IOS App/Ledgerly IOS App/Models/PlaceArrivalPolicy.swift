import Foundation

enum PlaceArrivalPolicy {
    static let maximumRegions = 20
    static let defaultRadius = 150.0

    static func radius(_ value: Double) -> Double {
        min(500, max(50, value.isFinite ? value : defaultRadius))
    }

    static func activePlaces(_ places: [LedgerPlace], enabledIDs: Set<UUID>,
                             visits: [PlaceVisit] = [], pinnedIDs: Set<UUID> = [],
                             now: Date = .now) -> [LedgerPlace] {
        places.filter { enabledIDs.contains($0.id) && $0.isValid }
            .sorted { first, second in
                let firstScore = priority(for: first.id, visits: visits, pinnedIDs: pinnedIDs, now: now)
                let secondScore = priority(for: second.id, visits: visits, pinnedIDs: pinnedIDs, now: now)
                if firstScore != secondScore { return firstScore > secondScore }
                let order = first.name.localizedStandardCompare(second.name)
                return order == .orderedSame ? first.id.uuidString < second.id.uuidString : order == .orderedAscending
            }
            .prefix(maximumRegions)
            .map { $0 }
    }

    static func priority(for placeID: UUID, visits: [PlaceVisit], pinnedIDs: Set<UUID>, now: Date) -> Int {
        let recent = visits.filter {
            $0.placeID == placeID && !$0.isAbandoned &&
            now.timeIntervalSince($0.enteredAt) >= 0 && now.timeIntervalSince($0.enteredAt) <= 90 * 86_400
        }
        let count = min(recent.count, 50)
        let recency = recent.map { max(0, 90 - Int(now.timeIntervalSince($0.enteredAt) / 86_400)) }.max() ?? 0
        return (pinnedIDs.contains(placeID) ? 10_000 : 0) + count * 20 + recency
    }

    static func shouldPrompt(placeID: UUID, now: Date, lastPrompt: Date?,
                             entries: [LedgerEntry]) -> Bool {
        if let lastPrompt, now.timeIntervalSince(lastPrompt) < 30 * 60 { return false }
        return !entries.contains { entry in
            entry.kind == .expense && entry.location?.placeID == placeID &&
            abs(now.timeIntervalSince(entry.date)) < 30 * 60
        }
    }

}
