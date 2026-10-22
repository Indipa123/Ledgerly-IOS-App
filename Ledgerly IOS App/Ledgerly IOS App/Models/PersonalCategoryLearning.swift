import Foundation

nonisolated struct PersonalCategoryExample: Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let label: String
    let kind: Int16
    let date: Date
    var correctionDate: Date? = nil
    var availableAt: Date { max(date, correctionDate ?? date) }
}

nonisolated struct PersonalCategoryScore: Sendable {
    let expected: String
    let predicted: String?
    let confidence: Double
    let margin: Double
    let similarity: Double
    var independentSupport: Int? = nil
}

nonisolated struct PersonalCategoryClassMetrics: Codable, Equatable, Identifiable, Sendable {
    var id: String { label }
    let label: String
    var training = 0
    var actual = 0
    var predicted = 0
    var correct = 0
    var abstained = 0
    var confusions: [String: Int] = [:]
    var precision: Double? { predicted == 0 ? nil : Double(correct) / Double(predicted) }
    var recall: Double? { actual == 0 ? nil : Double(correct) / Double(actual) }
}

nonisolated struct PersonalCategoryScoreBin: Codable, Equatable, Identifiable, Sendable {
    var id: Int { index }
    let index: Int
    var count = 0
    var correct = 0
    var scoreSum = 0.0
    var meanScore: Double? { count == 0 ? nil : scoreSum / Double(count) }
    var accuracy: Double? { count == 0 ? nil : Double(correct) / Double(count) }
}

nonisolated struct PersonalCategoryReliabilitySeries: Codable, Equatable, Sendable {
    var bins: [PersonalCategoryScoreBin] = (0..<5).map { .init(index: $0) }
    var count: Int { bins.reduce(0) { $0 + $1.count } }
    var correct: Int { bins.reduce(0) { $0 + $1.correct } }
    var meanScore: Double? { count == 0 ? nil : bins.reduce(0) { $0 + $1.scoreSum } / Double(count) }
    var accuracy: Double? { count == 0 ? nil : Double(correct) / Double(count) }
    var binnedGap: Double? {
        guard count > 0 else { return nil }
        let weighted = bins.reduce(0.0) { sum, bin in
            guard let score = bin.meanScore, let accuracy = bin.accuracy else { return sum }
            return sum + Double(bin.count) * abs(score - accuracy)
        }
        return weighted / Double(count)
    }

    mutating func record(score: Double, correct: Bool) {
        guard score.isFinite, (0...1).contains(score) else { return }
        let index = min(4, Int(score * 5))
        bins[index].count += 1
        bins[index].scoreSum += score
        if correct { bins[index].correct += 1 }
    }
}

nonisolated struct PersonalCategoryReliabilityReport: Codable, Equatable, Sendable {
    var all = PersonalCategoryReliabilitySeries()
    var shown = PersonalCategoryReliabilitySeries()
    var unscored = 0
}

nonisolated struct PersonalCategoryMetrics: Codable, Sendable {
    var total = 0
    var suggested = 0
    var correct = 0
    var exactSuggested = 0
    var exactCorrect = 0
    var majorityCorrect = 0
    var perCategory: [PersonalCategoryClassMetrics]? = nil
    var reliability: PersonalCategoryReliabilityReport? = nil
    var accuracy: Double? { suggested == 0 ? nil : Double(correct) / Double(suggested) }
    var coverage: Double { total == 0 ? 0 : Double(suggested) / Double(total) }
}

nonisolated struct PersonalCategoryAttempt: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let kind: Int16
    let exampleCount: Int
    let trainingCount: Int
    let calibrationCount: Int
    let threshold: Double?
    let metrics: PersonalCategoryMetrics
    let activated: Bool
    let reason: String
    var trigger: String? = nil
    var correctedTrainingExamples: Int? = nil
    var weightedTrainingRows: Int? = nil
    var calibrationCheck: PersonalCategoryCalibrationReport? = nil
}

nonisolated struct PersonalCategoryModelRecord: Codable, Sendable {
    let version: UUID
    let kind: Int16
    let threshold: Double
    let training: [PersonalCategoryExample]
    var correctionWeightingVersion: Int? = nil
}

nonisolated struct PersonalCategoryArchive: Codable, Sendable {
    var schema = 1
    var models: [PersonalCategoryModelRecord] = []
    var sourceExamples: [PersonalCategoryExample] = []
    var attempts: [PersonalCategoryAttempt] = []
    var automation: PersonalRetrainingState?
    // Explicit approval belongs to an exact local model version, never its replacement.
    var calibratedEstimateVersions: Set<UUID>?

    func isValid(for examples: [PersonalCategoryExample]) -> Bool {
        let current = Dictionary(uniqueKeysWithValues: examples.map { ($0.id, $0) })
        return schema == 1 && sourceExamples.allSatisfy { current[$0.id] == $0 }
    }
}

nonisolated enum PersonalCategoryPolicy {
    static let dimensions = 512
    static let minimumExamples = 15
    static let minimumSimilarity = 0.82
    static let minimumMargin = 0.25
    static let precisionTarget = 0.90

    struct Split: Sendable {
        let training: [PersonalCategoryExample]
        let calibration: [PersonalCategoryExample]
        let test: [PersonalCategoryExample]
    }

    /// Separate types, then reserve later transactions for calibration and a final untouched test.
    static func split(_ examples: [PersonalCategoryExample], kind: Int16) -> Split? {
        let ordered = examples.filter { $0.kind == kind }.sorted {
            $0.availableAt == $1.availableAt ? $0.id.uuidString < $1.id.uuidString : $0.availableAt < $1.availableAt
        }.suffix(2_000)
        guard ordered.count >= minimumExamples else { return nil }
        let rows = Array(ordered)
        let trainingEnd = rows.count * 3 / 5
        let calibrationEnd = rows.count * 4 / 5
        let earlier = Array(rows[..<trainingEnd])
        let counts = Dictionary(grouping: earlier, by: \.label).mapValues(\.count)
        let labels = Set(counts.filter { $0.value >= 3 }.keys)
        guard labels.count >= 2 else { return nil }
        return Split(training: earlier.filter { labels.contains($0.label) },
                     calibration: Array(rows[trainingEnd..<calibrationEnd]),
                     test: Array(rows[calibrationEnd...]))
    }

    /// Repeat only older training rows, after reserving unique calibration and test IDs.
    static func updateExamples(for split: Split) -> [PersonalCategoryExample] {
        split.training.flatMap { row in row.correctionDate == nil ? [row] : [row, row] }
    }

    /// Fixed FNV-1a hashing is stable across launches (Swift's Hasher is deliberately random).
    static func features(_ normalizedText: String) -> [Double] {
        let chars = Array("^" + normalizedText.prefix(256) + "$")
        var values = Array(repeating: 0.0, count: dimensions)
        for width in 2...4 where chars.count >= width {
            for start in 0...(chars.count - width) {
                var hash: UInt64 = 14_695_981_039_346_656_037
                for byte in String(chars[start..<start + width]).utf8 {
                    hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
                }
                values[Int(hash % UInt64(dimensions))] += 1
            }
        }
        let length = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return length == 0 ? values : values.map { $0 / length }
    }

    static func similarity(_ left: [Double], _ right: [Double]) -> Double {
        guard left.count == dimensions, right.count == dimensions else { return 0 }
        return zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
    }

    static func accepts(_ score: PersonalCategoryScore, threshold: Double) -> Bool {
        score.predicted != nil && score.confidence.isFinite && score.margin.isFinite &&
        (score.independentSupport.map { $0 >= 2 } ?? true) &&
        score.similarity.isFinite && score.confidence >= threshold && score.confidence <= 1 &&
        score.margin >= minimumMargin && score.similarity >= minimumSimilarity
    }

    /// Scores are not claimed to be calibrated probabilities. Select a gate on a separate slice.
    static func threshold(calibration: [PersonalCategoryScore], exampleCount: Int) -> Double? {
        if exampleCount < 50 { return 1 }
        let candidates = Set(calibration.map(\.confidence).filter { $0.isFinite && $0 >= 0.67 && $0 <= 1 })
        var best: (threshold: Double, count: Int)?
        for threshold in candidates.sorted(by: >) {
            let shown = calibration.filter { accepts($0, threshold: threshold) }
            guard shown.count >= 5,
                  Double(shown.filter { $0.expected == $0.predicted }.count) / Double(shown.count) >= precisionTarget
            else { continue }
            if best == nil || shown.count > best!.count { best = (threshold, shown.count) }
        }
        return best?.threshold
    }

    static func metrics(scores: [PersonalCategoryScore], threshold: Double,
                        training: [PersonalCategoryExample], test: [PersonalCategoryExample]) -> PersonalCategoryMetrics {
        var report = PersonalCategoryMetrics(total: test.count)
        let exact = Dictionary(grouping: training, by: \.text)
        let majority = winner(training.map(\.label))
        var classes: [String: PersonalCategoryClassMetrics] = [:]
        var reliability = PersonalCategoryReliabilityReport()
        for row in training { classes[row.label, default: .init(label: row.label)].training += 1 }
        for (index, row) in test.enumerated() {
            if index < scores.count, let predicted = scores[index].predicted,
               scores[index].confidence.isFinite, (0...1).contains(scores[index].confidence) {
                reliability.all.record(score: scores[index].confidence, correct: predicted == row.label)
                if accepts(scores[index], threshold: threshold) {
                    reliability.shown.record(score: scores[index].confidence, correct: predicted == row.label)
                }
            } else { reliability.unscored += 1 }
            classes[row.label, default: .init(label: row.label)].actual += 1
            if index < scores.count, accepts(scores[index], threshold: threshold),
               let predicted = scores[index].predicted {
                report.suggested += 1
                classes[predicted, default: .init(label: predicted)].predicted += 1
                if predicted == row.label {
                    report.correct += 1
                    classes[row.label, default: .init(label: row.label)].correct += 1
                } else {
                    classes[row.label, default: .init(label: row.label)].confusions[predicted, default: 0] += 1
                }
            } else {
                classes[row.label, default: .init(label: row.label)].abstained += 1
            }
            if let matches = exact[row.text], let label = winner(matches.map(\.label)) {
                report.exactSuggested += 1
                if label == row.label { report.exactCorrect += 1 }
            }
            if majority == row.label { report.majorityCorrect += 1 }
        }
        report.perCategory = classes.values.sorted { $0.label < $1.label }
        report.reliability = reliability
        return report
    }

    static func canActivate(_ candidate: PersonalCategoryMetrics, previous: PersonalCategoryMetrics?) -> Bool {
        guard let accuracy = candidate.accuracy, accuracy >= precisionTarget else { return false }
        guard let previous, let oldAccuracy = previous.accuracy else { return true }
        return candidate.total == previous.total && accuracy + 0.000_001 >= oldAccuracy
    }

    private static func winner(_ labels: [String]) -> String? {
        Dictionary(grouping: labels, by: { $0 }).mapValues(\.count).sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.first?.key
    }
}
