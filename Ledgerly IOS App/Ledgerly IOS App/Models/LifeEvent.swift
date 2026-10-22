import Foundation

enum LifeEventKind: String, CaseIterable, Identifiable {
    case wedding, funeral, dana, avurudu, graduation, trip, renovation, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wedding: "Wedding"
        case .funeral: "Funeral"
        case .dana: "Dana"
        case .avurudu: "Avurudu"
        case .graduation: "Graduation"
        case .trip: "Trip"
        case .renovation: "Renovation"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .wedding: "heart.fill"
        case .funeral: "leaf.fill"
        case .dana: "hands.sparkles.fill"
        case .avurudu: "sun.max.fill"
        case .graduation: "graduationcap.fill"
        case .trip: "suitcase.rolling.fill"
        case .renovation: "hammer.fill"
        case .other: "calendar.badge.clock"
        }
    }
}

struct LifeEvent: Identifiable, Equatable {
    let id: UUID
    var name: String
    var kind: LifeEventKind
    var budget: Decimal
    var startDate: Date
    var endDate: Date
    var completedAt: Date? = nil
    var completionSpent: Decimal? = nil
    var createdAt: Date = .now
    var updatedAt: Date = .now

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        budget > 0 && startDate <= endDate
    }

    func expenses(in entries: [LedgerEntry]) -> [LedgerEntry] {
        entries.filter { $0.kind == .expense && $0.eventID == id }
    }

    func spent(in entries: [LedgerEntry]) -> Decimal {
        expenses(in: entries).reduce(.zero) { $0 + $1.amount }
    }

    func projectedSpent(in entries: [LedgerEntry], adding amount: Decimal,
                        replacing entryID: UUID?) -> Decimal {
        expenses(in: entries).filter { $0.id != entryID }
            .reduce(amount) { $0 + $1.amount }
    }
}
