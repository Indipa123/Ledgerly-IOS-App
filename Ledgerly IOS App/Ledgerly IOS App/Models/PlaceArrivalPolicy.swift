import Foundation

struct PlaceQuietHours: Codable, Equatable {
    var enabled = false
    var startMinute = 22 * 60
    var endMinute = 8 * 60

    var isValid: Bool {
        (0..<1_440).contains(startMinute) && (0..<1_440).contains(endMinute) &&
            startMinute != endMinute
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, isValid else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return false }
        let value = hour * 60 + minute
        return startMinute < endMinute
            ? value >= startMinute && value < endMinute
            : value >= startMinute || value < endMinute
    }
}

struct PlacePromptDismissalState: Codable, Equatable {
    static let threshold = 3
    private(set) var dismissedVisitIDs: Set<UUID> = []
    private(set) var acceptingVisitsAfter: Date?

    var streak: Int { dismissedVisitIDs.count }
    var isAutomaticallyMuted: Bool { streak >= Self.threshold }

    @discardableResult
    mutating func dismiss(visit: PlaceVisit, at date: Date, enabledAfter: Date? = nil) -> Bool {
        let cutoff = max(acceptingVisitsAfter ?? .distantPast, enabledAfter ?? .distantPast)
        guard !isAutomaticallyMuted, !visit.isAbandoned, visit.enteredAt > cutoff,
              visit.enteredAt <= date,
              date.timeIntervalSince(visit.enteredAt) < PlaceVisitPolicy.abandonedAfter else { return false }
        return dismissedVisitIDs.insert(visit.id).inserted
    }

    mutating func reset(at date: Date) {
        dismissedVisitIDs.removeAll()
        // Delayed notification callbacks from an earlier visit must not re-mute a place.
        acceptingVisitsAfter = max(acceptingVisitsAfter ?? .distantPast, date)
    }
}

enum PlacePromptFeedbackPolicy {
    static func newlyRecordedPlaceIDs(previous: [LedgerEntry], current: [LedgerEntry]) -> Set<UUID> {
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(current.compactMap { entry in
            guard entry.kind == .expense, entry.amount > 0, let placeID = entry.location?.placeID else { return nil }
            if let existing = old[entry.id], existing.kind == .expense, existing.location?.placeID == placeID {
                return nil
            }
            return placeID
        })
    }
}

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

    static func allowsPrompts(isMuted: Bool, quietHours: PlaceQuietHours,
                              now: Date, calendar: Calendar = .current) -> Bool {
        !isMuted && !quietHours.contains(now, calendar: calendar)
    }

    static func shouldPrompt(placeID: UUID, now: Date, lastPrompt: Date?,
                             entries: [LedgerEntry], isMuted: Bool = false,
                             quietHours: PlaceQuietHours = .init(),
                             calendar: Calendar = .current) -> Bool {
        guard allowsPrompts(isMuted: isMuted, quietHours: quietHours,
                            now: now, calendar: calendar) else { return false }
        if let lastPrompt, now.timeIntervalSince(lastPrompt) < 30 * 60 { return false }
        return !entries.contains { entry in
            entry.kind == .expense && entry.location?.placeID == placeID &&
            abs(now.timeIntervalSince(entry.date)) < 30 * 60
        }
    }

}
