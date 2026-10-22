import Foundation

enum PlaceAlertKind: String, CaseIterable {
    case arrival, departure
}

enum PlaceAlertSound: String, Codable, CaseIterable, Identifiable {
    case chime, system, silent

    var id: Self { self }
    var title: String {
        switch self {
        case .chime: "Ledgerly chime"
        case .system: "System sound"
        case .silent: "Silent"
        }
    }

    func filename(for kind: PlaceAlertKind) -> String? {
        guard self == .chime else { return nil }
        return kind == .arrival ? "ledgerly-arrival.wav" : "ledgerly-departure.wav"
    }
}

struct PlaceNotificationPreferences: Codable, Equatable {
    var departureEnabled = true
    var arrivalSound: PlaceAlertSound = .chime
    var departureSound: PlaceAlertSound = .chime

    func sound(for kind: PlaceAlertKind) -> PlaceAlertSound {
        kind == .arrival ? arrivalSound : departureSound
    }
}

enum PlaceDepartureNotice: Equatable {
    case recorded(PlaceVisitSpendingSummary)
    case unrecorded

    static func make(for visit: PlaceVisit, entries: [LedgerEntry], enabled: Bool) -> Self? {
        // A refreshed outside-state is an estimate, not a new boundary crossing.
        // Do not notify again for old visits discovered when reopening the app.
        guard enabled, !visit.isOpen, !visit.isAbandoned, !visit.isReconciled else { return nil }
        if let summary = PlaceVisitPolicy.spendingSummary(for: visit, entries: entries) {
            return .recorded(summary)
        }
        return .unrecorded
    }
}
