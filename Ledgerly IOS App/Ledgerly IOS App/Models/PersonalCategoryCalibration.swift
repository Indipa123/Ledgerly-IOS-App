import Foundation

/// A top-label correctness estimate, not a distribution over expense categories.
nonisolated struct PersonalCategorySigmoid: Codable, Equatable, Sendable {
    let slope: Double
    let intercept: Double

    func estimate(_ score: Double) -> Double? {
        guard score.isFinite, (0...1).contains(score), slope.isFinite,
              (0...10).contains(slope), intercept.isFinite, (-10...10).contains(intercept) else { return nil }
        let bounded = min(0.999, max(0.001, score))
        let z = slope * log(bounded / (1 - bounded)) + intercept
        return 1 / (1 + exp(-z))
    }
}

nonisolated struct PersonalCategoryCalibrationMetrics: Codable, Equatable, Sendable {
    let brierScore: Double?
    let reliability: PersonalCategoryReliabilitySeries
}

nonisolated enum PersonalCategoryCalibrationStatus: String, Codable, Sendable {
    case insufficientCalibration, insufficientTest, improved, notImproved

    var label: String {
        switch self {
        case .insufficientCalibration: "More calibration examples needed"
        case .insufficientTest: "More test examples needed"
        case .improved: "Improved on this test"
        case .notImproved: "No improvement on this test"
        }
    }
}

/// Aggregate fitting/evaluation evidence. No labels, descriptions or individual scores are retained.
nonisolated struct PersonalCategoryCalibrationReport: Codable, Equatable, Sendable {
    let methodVersion: Int
    let status: PersonalCategoryCalibrationStatus
    let calibrationCount: Int
    let calibrationCorrect: Int
    let calibrationSkipped: Int
    let testCount: Int
    let testCorrect: Int
    let testSkipped: Int
    let transform: PersonalCategorySigmoid?
    let raw: PersonalCategoryCalibrationMetrics
    let adjusted: PersonalCategoryCalibrationMetrics?
}

nonisolated enum PersonalCategoryCalibration {
    private struct Observation {
        let score: Double
        let correct: Bool
    }

    /// The caller splits model training, calibration and test data before fitting.
    /// Fixed support rules and fit settings never use the final test labels.
    static func evaluate(calibration: [PersonalCategoryScore], test: [PersonalCategoryScore]) -> PersonalCategoryCalibrationReport {
        let earlier = observations(calibration)
        let later = observations(test)
        let transform = fit(earlier)
        let raw = metrics(later, transform: nil)
        let adjusted = transform.map { metrics(later, transform: $0) }
        let testCorrect = later.filter(\.correct).count
        let status: PersonalCategoryCalibrationStatus
        if transform == nil { status = .insufficientCalibration }
        else if later.count < 20 || testCorrect < 3 || later.count - testCorrect < 3 {
            status = .insufficientTest
        } else if let before = raw.brierScore, let after = adjusted?.brierScore,
                  let rawGap = raw.reliability.binnedGap, let adjustedGap = adjusted?.reliability.binnedGap,
                  after < before - 0.000_001, adjustedGap <= rawGap + 0.000_001 {
            status = .improved
        } else { status = .notImproved }
        return .init(methodVersion: 1, status: status,
            calibrationCount: earlier.count, calibrationCorrect: earlier.filter(\.correct).count,
            calibrationSkipped: calibration.count - earlier.count, testCount: later.count,
            testCorrect: testCorrect, testSkipped: test.count - later.count,
            transform: transform, raw: raw, adjusted: adjusted)
    }

    private static func observations(_ scores: [PersonalCategoryScore]) -> [Observation] {
        scores.compactMap { score in
            guard !score.expected.isEmpty, let predicted = score.predicted, !predicted.isEmpty,
                  score.confidence.isFinite, (0...1).contains(score.confidence) else { return nil }
            return .init(score: score.confidence, correct: predicted == score.expected)
        }
    }

    private static func fit(_ rows: [Observation]) -> PersonalCategorySigmoid? {
        let correct = rows.filter(\.correct).count
        guard rows.count >= 30, correct >= 5, rows.count - correct >= 5 else { return nil }
        let inputs = rows.map { row -> (Double, Double) in
            let p = min(0.999, max(0.001, row.score))
            return (log(p / (1 - p)), row.correct ? 1 : 0)
        }
        // Regularised logistic fit; nonnegative slope preserves score ordering.
        var slope = 1.0, intercept = 0.0
        for _ in 0..<800 {
            var slopeGradient = 0.0, interceptGradient = 0.0
            for (x, y) in inputs {
                let residual = 1 / (1 + exp(-(slope * x + intercept))) - y
                slopeGradient += residual * x
                interceptGradient += residual
            }
            slopeGradient = slopeGradient / Double(inputs.count) + 0.01 * (slope - 1)
            interceptGradient = interceptGradient / Double(inputs.count) + 0.01 * intercept
            slope = min(10, max(0, slope - 0.05 * slopeGradient))
            intercept = min(10, max(-10, intercept - 0.05 * interceptGradient))
        }
        guard slope.isFinite, intercept.isFinite else { return nil }
        return .init(slope: slope, intercept: intercept)
    }

    private static func metrics(_ rows: [Observation], transform: PersonalCategorySigmoid?) -> PersonalCategoryCalibrationMetrics {
        var reliability = PersonalCategoryReliabilitySeries()
        var squaredError = 0.0
        for row in rows {
            let estimate = transform?.estimate(row.score) ?? row.score
            reliability.record(score: estimate, correct: row.correct)
            squaredError += pow(estimate - (row.correct ? 1 : 0), 2)
        }
        return .init(brierScore: rows.isEmpty ? nil : squaredError / Double(rows.count), reliability: reliability)
    }
}

/// Display policy only: calibration never changes which category passes the raw gate.
nonisolated enum PersonalCategoryCalibrationDeployment {
    static func isEligible(model: PersonalCategoryModelRecord, attempt: PersonalCategoryAttempt?) -> Bool {
        guard let attempt, attempt.id == model.version, attempt.kind == model.kind,
              [Int16(0), 1].contains(model.kind),
              attempt.activated, attempt.threshold == model.threshold,
              attempt.metrics.suggested > 0, attempt.metrics.suggested <= attempt.metrics.total,
              attempt.metrics.correct >= 0, attempt.metrics.correct <= attempt.metrics.suggested,
              (attempt.metrics.accuracy ?? 0) >= PersonalCategoryPolicy.precisionTarget,
              model.threshold.isFinite, (0.67...1).contains(model.threshold),
              let check = attempt.calibrationCheck, check.methodVersion == 1,
              check.status == .improved, let transform = check.transform,
              transform.estimate(0.5) != nil,
              check.calibrationCount >= 30, check.calibrationCorrect >= 5,
              check.calibrationCorrect <= check.calibrationCount - 5,
              check.testCount >= 20, check.testCorrect >= 3,
              check.testCorrect <= check.testCount - 3,
              check.calibrationSkipped >= 0, check.testSkipped >= 0,
              check.calibrationCount <= attempt.calibrationCount,
              check.calibrationSkipped == attempt.calibrationCount - check.calibrationCount,
              check.testCount <= attempt.metrics.total,
              check.testSkipped == attempt.metrics.total - check.testCount,
              valid(check.raw, count: check.testCount, correct: check.testCorrect),
              let adjusted = check.adjusted,
              valid(adjusted, count: check.testCount, correct: check.testCorrect),
              let before = check.raw.brierScore, let after = adjusted.brierScore,
              let rawGap = check.raw.reliability.binnedGap,
              let adjustedGap = adjusted.reliability.binnedGap else { return false }
        // Recheck the saved evidence rather than trusting the status label alone.
        return after < before - 0.000_001 && adjustedGap <= rawGap + 0.000_001
    }

    static func estimate(score: PersonalCategoryScore, model: PersonalCategoryModelRecord,
                         attempt: PersonalCategoryAttempt?, approvedVersions: Set<UUID>) -> Double? {
        guard approvedVersions.contains(model.version), isEligible(model: model, attempt: attempt),
              PersonalCategoryPolicy.accepts(score, threshold: model.threshold) else { return nil }
        return attempt?.calibrationCheck?.transform?.estimate(score.confidence)
    }

    static func retainingApprovals(_ approved: Set<UUID>, models: [PersonalCategoryModelRecord],
                                   attempts: [PersonalCategoryAttempt]) -> Set<UUID> {
        Set(models.filter { model in
            approved.contains(model.version) &&
                isEligible(model: model, attempt: attempts.first { $0.id == model.version })
        }.map(\.version))
    }

    private static func valid(_ metrics: PersonalCategoryCalibrationMetrics, count: Int, correct: Int) -> Bool {
        guard let brier = metrics.brierScore, brier.isFinite, (0...1).contains(brier),
              metrics.reliability.bins.map(\.index) == Array(0..<5),
              metrics.reliability.bins.allSatisfy({ bin in
                  bin.count >= 0 && bin.correct >= 0 && bin.correct <= bin.count &&
                      bin.scoreSum.isFinite && bin.scoreSum >= 0 && bin.scoreSum <= Double(bin.count)
              }) else { return false }
        return metrics.reliability.count == count && metrics.reliability.correct == correct
    }
}
