import Foundation
import Testing
@testable import LedgerlyDomain

struct PersonalCategoryCalibrationDeploymentTests {
    private func fixture() -> (PersonalCategoryModelRecord, PersonalCategoryAttempt) {
        func rows(_ count: Int, correct: Int) -> [PersonalCategoryScore] {
            (0..<count).map { .init(expected: "a", predicted: $0 < correct ? "a" : "b",
                confidence: 0.99, margin: 0.9, similarity: 1) }
        }
        let report = PersonalCategoryCalibration.evaluate(calibration: rows(60, correct: 42),
                                                          test: rows(40, correct: 28))
        let model = PersonalCategoryModelRecord(version: UUID(), kind: 0, threshold: 0.9, training: [])
        var metrics = PersonalCategoryMetrics()
        metrics.total = 40
        metrics.suggested = 10
        metrics.correct = 10
        let attempt = PersonalCategoryAttempt(id: model.version, date: .now, kind: 0,
            exampleCount: 300, trainingCount: 200, calibrationCount: 60, threshold: 0.9,
            metrics: metrics, activated: true, reason: "Test fixture", calibrationCheck: report)
        return (model, attempt)
    }

    private func changing(_ attempt: PersonalCategoryAttempt, _ mutate: (inout [String: Any]) -> Void) throws -> PersonalCategoryAttempt {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(attempt)) as? [String: Any])
        mutate(&object)
        return try JSONDecoder().decode(PersonalCategoryAttempt.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func supportedImprovementRequiresExplicitApprovalForTheExactVersion() throws {
        let (model, attempt) = fixture()
        let score = PersonalCategoryScore(expected: "", predicted: "a", confidence: 0.99,
                                          margin: 0.9, similarity: 1, independentSupport: 2)
        #expect(PersonalCategoryCalibrationDeployment.isEligible(model: model, attempt: attempt))
        #expect(PersonalCategoryCalibrationDeployment.estimate(score: score, model: model, attempt: attempt,
                                                               approvedVersions: []) == nil)
        #expect(PersonalCategoryCalibrationDeployment.estimate(score: score, model: model, attempt: attempt,
                                                               approvedVersions: [UUID()]) == nil)
        let value = try #require(PersonalCategoryCalibrationDeployment.estimate(score: score, model: model,
            attempt: attempt, approvedVersions: [model.version]))
        #expect(value.isFinite && (0...1).contains(value))
        #expect(value == attempt.calibrationCheck?.transform?.estimate(score.confidence))
        #expect(value < score.confidence)
    }

    @Test func missingMismatchedInactiveAndUnsupportedEvidenceStayUnavailable() throws {
        let (model, attempt) = fixture()
        #expect(!PersonalCategoryCalibrationDeployment.isEligible(model: model, attempt: nil))
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["id"] = UUID().uuidString }, { $0["kind"] = 1 },
            { $0["activated"] = false }, { $0["threshold"] = 0.95 },
            { object in
                var metrics = object["metrics"] as! [String: Any]
                metrics["correct"] = 0
                object["metrics"] = metrics
            },
            { $0.removeValue(forKey: "calibrationCheck") },
            { object in
                var report = object["calibrationCheck"] as! [String: Any]
                report["methodVersion"] = 2
                object["calibrationCheck"] = report
            }
        ]
        for mutation in mutations {
            #expect(!PersonalCategoryCalibrationDeployment.isEligible(model: model,
                attempt: try changing(attempt, mutation)))
        }
    }

    @Test func savedStatusCannotOverrideInsufficientInconsistentOrWorseEvidence() throws {
        let (model, attempt) = fixture()
        for (key, value) in [("calibrationCount", 29), ("calibrationCorrect", 4),
                              ("testCount", 19), ("testCorrect", 2), ("testSkipped", -1)] {
            let changed = try changing(attempt) { object in
                var report = object["calibrationCheck"] as! [String: Any]
                report[key] = value
                object["calibrationCheck"] = report
            }
            #expect(!PersonalCategoryCalibrationDeployment.isEligible(model: model, attempt: changed))
        }
        for field in ["brier", "bins", "transform", "status"] {
            let changed = try changing(attempt) { object in
                var report = object["calibrationCheck"] as! [String: Any]
                if field == "brier" {
                    var adjusted = report["adjusted"] as! [String: Any]
                    adjusted["brierScore"] = 1.0
                    report["adjusted"] = adjusted
                } else if field == "bins" {
                    var adjusted = report["adjusted"] as! [String: Any]
                    adjusted["reliability"] = ["bins": []]
                    report["adjusted"] = adjusted
                } else if field == "transform" {
                    report["transform"] = ["slope": -1, "intercept": 0]
                } else { report["status"] = "notImproved" }
                object["calibrationCheck"] = report
            }
            #expect(!PersonalCategoryCalibrationDeployment.isEligible(model: model, attempt: changed))
        }
    }

    @Test func displayEstimatesCannotBypassAnyOriginalSuggestionGate() {
        let (model, attempt) = fixture()
        let scores: [PersonalCategoryScore] = [
            .init(expected: "", predicted: "a", confidence: 0.89, margin: 0.9, similarity: 1),
            .init(expected: "", predicted: "a", confidence: 0.99, margin: 0.2, similarity: 1),
            .init(expected: "", predicted: "a", confidence: 0.99, margin: 0.9, similarity: 0.8),
            .init(expected: "", predicted: "a", confidence: 0.99, margin: 0.9, similarity: 1, independentSupport: 1),
            .init(expected: "", predicted: nil, confidence: 0.99, margin: 0.9, similarity: 1),
            .init(expected: "", predicted: "a", confidence: .nan, margin: 0.9, similarity: 1)
        ]
        for score in scores {
            #expect(!PersonalCategoryPolicy.accepts(score, threshold: model.threshold))
            #expect(PersonalCategoryCalibrationDeployment.estimate(score: score, model: model, attempt: attempt,
                approvedVersions: [model.version]) == nil)
        }
    }

    @Test func replacementInvalidationAndPrunedHistoryRemoveApprovals() {
        let (old, attempt) = fixture()
        let replacement = PersonalCategoryModelRecord(version: UUID(), kind: old.kind,
                                                       threshold: old.threshold, training: [])
        let approved: Set<UUID> = [old.version]
        #expect(PersonalCategoryCalibrationDeployment.retainingApprovals(approved, models: [old], attempts: [attempt]) == approved)
        #expect(PersonalCategoryCalibrationDeployment.retainingApprovals(approved, models: [replacement], attempts: [attempt]).isEmpty)
        #expect(PersonalCategoryCalibrationDeployment.retainingApprovals(approved, models: [], attempts: [attempt]).isEmpty)
        #expect(PersonalCategoryCalibrationDeployment.retainingApprovals(approved, models: [old], attempts: []).isEmpty)
    }

    @Test func oldArchivesDefaultOffAndPreferencesRoundTripWithoutGlobalState() throws {
        let legacy = Data(#"{"schema":1,"models":[],"sourceExamples":[],"attempts":[]}"#.utf8)
        #expect(try JSONDecoder().decode(PersonalCategoryArchive.self, from: legacy).calibratedEstimateVersions == nil)
        let (model, attempt) = fixture()
        var account = PersonalCategoryArchive()
        account.models = [model]
        account.attempts = [attempt]
        account.calibratedEstimateVersions = [model.version]
        let reopened = try JSONDecoder().decode(PersonalCategoryArchive.self, from: JSONEncoder().encode(account))
        #expect(reopened.calibratedEstimateVersions == [model.version])
        #expect(PersonalCategoryArchive().calibratedEstimateVersions == nil)
    }
}
