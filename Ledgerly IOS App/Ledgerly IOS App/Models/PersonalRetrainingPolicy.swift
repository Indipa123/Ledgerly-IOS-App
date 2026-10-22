import Foundation

nonisolated struct PersonalRetrainingState: Codable, Equatable, Sendable {
    var enabled = false
    var checkpointIDs: Set<UUID> = []
    var correctionIDs: Set<UUID> = []
    var lastAttemptAt: Date?
    var categoryRevision: String?

    mutating func completed(exampleIDs: Set<UUID>, revision: String, at date: Date) {
        checkpointIDs = exampleIDs
        correctionIDs = []
        categoryRevision = revision
        lastAttemptAt = date
    }
}

nonisolated enum PersonalRetrainingReason: String, Sendable {
    case firstModel = "First personal model"
    case newExamples = "10 new examples"
    case corrections = "3 corrected transactions"
    case categoriesChanged = "Categories changed"
    case weekly = "A week with new examples"
}

nonisolated enum PersonalRetrainingPolicy {
    static func reason(state: PersonalRetrainingState, exampleIDs: Set<UUID>, revision: String,
                       hasTrainableData: Bool, now: Date = .now) -> PersonalRetrainingReason? {
        guard state.enabled, hasTrainableData else { return nil }
        guard let previous = state.lastAttemptAt else { return .firstModel }
        if state.categoryRevision != revision { return .categoriesChanged }
        if state.correctionIDs.intersection(exampleIDs).count >= 3 { return .corrections }
        let newCount = exampleIDs.subtracting(state.checkpointIDs).count
        if newCount >= 10 { return .newExamples }
        if newCount > 0 && now.timeIntervalSince(previous) >= 7 * 86_400 { return .weekly }
        return nil
    }

    static func revision(_ categoryDescriptions: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in categoryDescriptions.sorted().joined(separator: "\0").utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
