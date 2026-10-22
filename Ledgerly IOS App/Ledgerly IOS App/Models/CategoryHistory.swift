import Foundation

enum CategoryCorrectionPolicy {
    static func date(for entry: LedgerEntry) -> Date? {
        if let change = entry.categoryChanges.last {
            guard change.origin == .thisDevice, change.to.categoryID == entry.categoryID,
                  change.to.kind == entry.kind.rawValue else { return nil }
            return change.recordedAt
        }
        guard let first = entry.categorySuggestion, first.source != nil, first.wasAccepted == false,
              first.savedCategoryID == entry.categoryID, first.kind == entry.kind.rawValue else { return nil }
        return first.recordedAt
    }
}

nonisolated struct CategorySelection: Codable, Equatable {
    let categoryID: UUID?
    let name: String
    let kind: Int16

    func hasSameIdentity(as other: Self) -> Bool {
        guard kind == other.kind else { return false }
        if let categoryID, let otherID = other.categoryID { return categoryID == otherID }
        return name.caseInsensitiveCompare(other.name) == .orderedSame
    }
}

nonisolated enum CategoryChangeOrigin: String, Codable {
    case thisDevice, cloudUpdate

    var label: String {
        switch self {
        case .thisDevice: "Saved on this device"
        case .cloudUpdate: "Received from cloud"
        }
    }
}

nonisolated struct CategoryChangeRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let recordedAt: Date
    let from: CategorySelection
    let to: CategorySelection
    let origin: CategoryChangeOrigin
}

/// Versioned envelope in the existing local-only binary field. Financial sync excludes it.
nonisolated struct CategoryHistoryMetadata: Codable, Equatable {
    let version: Int
    var firstSave: CategorySuggestionRecord?
    var changes: [CategoryChangeRecord]

    init(firstSave: CategorySuggestionRecord? = nil, changes: [CategoryChangeRecord] = []) {
        version = 1
        self.firstSave = firstSave
        self.changes = changes
    }

    static func decode(_ data: Data?) throws -> Self {
        guard let data else { return .init() }
        let decoder = JSONDecoder()
        if let metadata = try? decoder.decode(Self.self, from: data) {
            guard metadata.version == 1 else {
                throw DecodingError.dataCorrupted(.init(codingPath: [],
                    debugDescription: "Unsupported category history version."))
            }
            return metadata
        }
        // Before the envelope was introduced, the field contained a first-save snapshot.
        return .init(firstSave: try decoder.decode(CategorySuggestionRecord.self, from: data))
    }

    mutating func recordChange(from: CategorySelection, to: CategorySelection,
                               origin: CategoryChangeOrigin, at date: Date = .now) {
        guard !from.hasSameIdentity(as: to) else { return }
        changes.append(.init(id: UUID(), recordedAt: date, from: from, to: to, origin: origin))
    }
}
