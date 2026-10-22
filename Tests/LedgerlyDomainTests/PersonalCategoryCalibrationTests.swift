import Foundation
import Testing
@testable import LedgerlyDomain

struct PersonalCategoryCalibrationTests {
    private func score(_ value: Double, correct: Bool = true) -> PersonalCategoryScore {
        .init(expected: "PRIVATE_EXPECTED_LABEL", predicted: correct ? "PRIVATE_EXPECTED_LABEL" : "PRIVATE_WRONG_LABEL",
              confidence: value, margin: 1, similarity: 1)
    }

    private func rows(count: Int, correct: Int, confidence: Double = 0.99) -> [PersonalCategoryScore] {
        (0..<count).map { score(confidence, correct: $0 < correct) }
    }

    @Test func fittingRequiresEnoughValidExamplesAndBothCorrectnessOutcomes() {
        for calibration in [rows(count: 29, correct: 20), rows(count: 30, correct: 26), rows(count: 30, correct: 4), []] {
            let result = PersonalCategoryCalibration.evaluate(calibration: calibration, test: rows(count: 30, correct: 20))
            #expect(result.status == .insufficientCalibration)
            #expect(result.transform == nil && result.adjusted == nil)
        }
        let fitted = PersonalCategoryCalibration.evaluate(calibration: rows(count: 30, correct: 25),
                                                          test: rows(count: 20, correct: 17))
        #expect(fitted.transform != nil && fitted.adjusted?.reliability.count == 20)
        for test in [rows(count: 19, correct: 10), rows(count: 20, correct: 18), rows(count: 20, correct: 2), []] {
            #expect(PersonalCategoryCalibration.evaluate(calibration: rows(count: 30, correct: 20), test: test).status == .insufficientTest)
        }
    }

    @Test func overconfidentFixtureImprovesOnSeparateTestWithoutUsingItsLabelsToFit() throws {
        let calibration = rows(count: 60, correct: 42)
        let report = PersonalCategoryCalibration.evaluate(calibration: calibration, test: rows(count: 40, correct: 28))
        #expect(report.status == .improved)
        #expect(try #require(report.adjusted?.brierScore) < #require(report.raw.brierScore))
        #expect(try #require(report.adjusted?.reliability.binnedGap) < #require(report.raw.reliability.binnedGap))
        let counterfactual = PersonalCategoryCalibration.evaluate(calibration: calibration, test: rows(count: 40, correct: 36))
        #expect(counterfactual.transform == report.transform)
        #expect(counterfactual.status == .notImproved)
        // Reordering calibration examples changes neither the result nor the fixed hyperparameters materially.
        let reordered = PersonalCategoryCalibration.evaluate(calibration: calibration.reversed(), test: rows(count: 40, correct: 28))
        #expect(abs(try #require(reordered.transform?.slope) - #require(report.transform?.slope)) < 0.000_001)
    }

    @Test func worseReservedResultsAreNotCalledImprovementAndRawBrierUsesAllValidScores() throws {
        let report = PersonalCategoryCalibration.evaluate(calibration: rows(count: 60, correct: 18),
                                                          test: rows(count: 40, correct: 36))
        #expect(report.status == .notImproved)
        #expect(try #require(report.adjusted?.brierScore) > #require(report.raw.brierScore))
        let known = PersonalCategoryCalibration.evaluate(calibration: [], test: [score(0.2), score(0.9, correct: false)])
        #expect(abs(try #require(known.raw.brierScore) - 0.725) < 0.000_001)
        #expect(known.raw.reliability.count == 2 && known.testCorrect == 1)
    }

    @Test func invalidScoresAreExcludedAndEmptyMetricsNeverInventZerosOrNaN() throws {
        let invalid = [score(.nan), score(.infinity), score(-1), score(1.1),
            PersonalCategoryScore(expected: "a", predicted: nil, confidence: 0.9, margin: 1, similarity: 1),
            PersonalCategoryScore(expected: "", predicted: "a", confidence: 0.9, margin: 1, similarity: 1)]
        let report = PersonalCategoryCalibration.evaluate(calibration: invalid, test: invalid + [score(0)])
        #expect(report.calibrationCount == 0 && report.calibrationSkipped == 6)
        #expect(report.testCount == 1 && report.testSkipped == 6 && report.raw.brierScore == 1)
        let empty = PersonalCategoryCalibration.evaluate(calibration: [], test: [])
        #expect(empty.raw.brierScore == nil && empty.raw.reliability.binnedGap == nil)
        #expect(empty.raw.reliability.count == 0 && empty.adjusted == nil)
        #expect(try JSONDecoder().decode(PersonalCategoryCalibrationReport.self,
                                         from: JSONEncoder().encode(empty)) == empty)
    }

    @Test func transformPreservesOrderingAndRejectsInvalidInputOrParameters() throws {
        let report = PersonalCategoryCalibration.evaluate(calibration: rows(count: 60, correct: 42), test: [])
        let transform = try #require(report.transform)
        let estimates = try [0.0, 0.1, 0.5, 0.9, 1.0].map { try #require(transform.estimate($0)) }
        #expect(estimates == estimates.sorted())
        #expect(estimates.allSatisfy { $0.isFinite && (0...1).contains($0) })
        #expect(transform.estimate(.nan) == nil && transform.estimate(.infinity) == nil)
        #expect(transform.estimate(-0.1) == nil && transform.estimate(1.1) == nil)
        #expect(PersonalCategorySigmoid(slope: -1, intercept: 0).estimate(0.5) == nil)
        #expect(PersonalCategorySigmoid(slope: 1, intercept: .nan).estimate(0.5) == nil)
    }

    @Test func reportRoundTripsExportsOnlyAggregatesAndOldAttemptsStayAbsent() throws {
        let report = PersonalCategoryCalibration.evaluate(calibration: rows(count: 60, correct: 42),
                                                          test: rows(count: 40, correct: 28))
        let attempt = PersonalCategoryAttempt(id: UUID(), date: .now, kind: 0,
            exampleCount: 300, trainingCount: 180, calibrationCount: 60, threshold: 0.9,
            metrics: .init(), activated: false, reason: "PRIVATE_REASON", calibrationCheck: report)
        let reopened = try JSONDecoder().decode(PersonalCategoryAttempt.self, from: JSONEncoder().encode(attempt))
        #expect(reopened.calibrationCheck == report)
        let export = PersonalCategoryEvaluationExport(attempt: reopened)
        let text = String(decoding: try export.jsonData(), as: UTF8.self)
        #expect(export.calibrationCheck == report)
        #expect(!text.contains("PRIVATE_EXPECTED_LABEL") && !text.contains("PRIVATE_WRONG_LABEL") && !text.contains("PRIVATE_REASON"))
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(attempt)) as? [String: Any])
        legacy.removeValue(forKey: "calibrationCheck")
        let old = try JSONDecoder().decode(PersonalCategoryAttempt.self,
                                           from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.calibrationCheck == nil)
        #expect(PersonalCategoryEvaluationExport(attempt: old).calibrationCheck == nil)
    }
}
