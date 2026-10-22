import Foundation

/// An explicit aggregate-only export, never an encoding of a model archive or its examples.
nonisolated struct PersonalCategoryEvaluationExport: Codable {
    struct Summary: Codable {
        let testTransactions: Int
        let suggestions: Int
        let correctSuggestions: Int
        let abstentions: Int
        let precision: Double?
        let coverage: Double
        let exactBaselineSuggestions: Int
        let exactBaselineCorrect: Int
        let majorityBaselineCorrect: Int
    }

    struct Confusion: Codable {
        let suggestedCategory: Int
        let count: Int
    }

    struct Category: Codable {
        let category: Int
        let name: String?
        let trainingTransactions: Int?
        let testTransactions: Int?
        let suggestions: Int?
        let correctSuggestions: Int?
        let abstentions: Int?
        let precision: Double?
        let recall: Double?
        let confusions: [Confusion]
    }

    let schemaVersion: Int
    let attemptID: UUID
    let evaluatedAt: Date
    let transactionType: String
    let activated: Bool
    let uniqueExamples: Int
    let uniqueTrainingTransactions: Int
    let calibrationTransactions: Int
    let confidenceThreshold: Double?
    let correctedTrainingTransactions: Int?
    let weightedTrainingRows: Int?
    let categoryNamesIncluded: Bool
    let summary: Summary
    let categories: [Category]?
    let reliability: PersonalCategoryReliabilityReport?
    let calibrationCheck: PersonalCategoryCalibrationReport?
    let notes: [String]

    init(attempt: PersonalCategoryAttempt, categoryNames: [String: String] = [:],
         includeCategoryNames: Bool = false) {
        schemaVersion = 1
        attemptID = attempt.id
        evaluatedAt = attempt.date
        transactionType = attempt.kind == 0 ? "expense" : attempt.kind == 1 ? "income" : "training"
        activated = attempt.activated
        uniqueExamples = attempt.exampleCount
        uniqueTrainingTransactions = attempt.trainingCount
        calibrationTransactions = attempt.calibrationCount
        confidenceThreshold = attempt.threshold
        correctedTrainingTransactions = attempt.correctedTrainingExamples
        weightedTrainingRows = attempt.weightedTrainingRows
        categoryNamesIncluded = includeCategoryNames
        let metrics = attempt.metrics
        summary = .init(testTransactions: metrics.total, suggestions: metrics.suggested,
            correctSuggestions: metrics.correct, abstentions: metrics.total - metrics.suggested,
            precision: metrics.accuracy, coverage: metrics.coverage,
            exactBaselineSuggestions: metrics.exactSuggested, exactBaselineCorrect: metrics.exactCorrect,
            majorityBaselineCorrect: metrics.majorityCorrect)
        if let rows = metrics.perCategory {
            let labels = Set(rows.map(\.label) + rows.flatMap { Array($0.confusions.keys) }).sorted()
            let identifiers = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($0.element, $0.offset + 1) })
            let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0) })
            categories = labels.map { label in
                let row = byLabel[label]
                let confusions = row?.confusions ?? [:]
                return .init(category: identifiers[label]!, name: includeCategoryNames ? categoryNames[label] : nil,
                    trainingTransactions: row?.training, testTransactions: row?.actual,
                    suggestions: row?.predicted, correctSuggestions: row?.correct, abstentions: row?.abstained,
                    precision: row?.precision, recall: row?.recall,
                    confusions: confusions.keys.sorted().map {
                        .init(suggestedCategory: identifiers[$0]!, count: confusions[$0]!)
                    })
            }
        } else { categories = nil }
        reliability = metrics.reliability
        calibrationCheck = attempt.calibrationCheck
        notes = [
            "Aggregate saved evaluation only. Transaction descriptions, amounts, notes, locations, account IDs, entry IDs, category IDs, source examples and model files are excluded.",
            "Category numbers apply within this report. Optional category names reflect the current ledger; saved metrics belong to the evaluation date.",
            "Absent breakdowns or weighting counts were not recorded by that attempt and are not reconstructed.",
            "Reliability bin indices 0-4 represent [0,0.2), [0.2,0.4), [0.4,0.6), [0.6,0.8), [0.8,1]. Each stores count, correct count and score sum.",
            "Live suggestion scores remain uncalibrated. An optional calibration check fits an experimental top-label correctness transform on the calibration slice and evaluates it on the test slice; it is not applied to suggestions. Small repeated retrospective evaluations do not establish future accuracy."
        ]
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
