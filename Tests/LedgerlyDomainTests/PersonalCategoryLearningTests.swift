import Foundation
import CoreML
import Testing
@testable import LedgerlyDomain

struct PersonalCategoryLearningTests {
    private func sample(_ index: Int, label: String? = nil, kind: Int16 = 0) -> PersonalCategoryExample {
        .init(id: UUID(), text: index.isMultiple(of: 2) ? "keellssupermarket" : "baristacoffee",
              label: label ?? (index.isMultiple(of: 2) ? "groceries" : "dining"), kind: kind,
              date: Date(timeIntervalSince1970: Double(1_700_000_000 + index * 86_400)))
    }

    private func score(_ confidence: Double, correct: Bool = true,
                       similarity: Double = 1, margin: Double = 0.5) -> PersonalCategoryScore {
        .init(expected: "a", predicted: correct ? "a" : "b", confidence: confidence,
              margin: margin, similarity: similarity)
    }

    @Test func featuresAreStableBoundedAndUseDescriptionSimilarity() {
        let vector = PersonalCategoryPolicy.features("keellssupermarket")
        #expect(vector.count == 512)
        #expect(vector == PersonalCategoryPolicy.features("keellssupermarket"))
        #expect(abs(PersonalCategoryPolicy.similarity(vector, vector) - 1) < 0.000_001)
        #expect(PersonalCategoryPolicy.similarity(vector, PersonalCategoryPolicy.features("keelssupermarket")) >
                PersonalCategoryPolicy.similarity(vector, PersonalCategoryPolicy.features("monthlysalary")))
        #expect(PersonalCategoryPolicy.features(String(repeating: "x", count: 1_000)) ==
                PersonalCategoryPolicy.features(String(repeating: "x", count: 256)))
    }

    @Test func coldStartAndTimeSlicesNeverLeakLaterLabels() throws {
        let rows = (0..<15).map { sample($0) }
        #expect(PersonalCategoryPolicy.split(Array(rows.prefix(14)), kind: 0) == nil)
        let split = try #require(PersonalCategoryPolicy.split(rows.reversed(), kind: 0))
        #expect(split.training.count == 9)
        #expect(split.calibration.count == 3)
        #expect(split.test.count == 3)
        #expect(split.training.last!.date <= split.calibration.first!.date)
        #expect(split.calibration.last!.date <= split.test.first!.date)
        #expect(Set(split.training.map(\.id)).isDisjoint(with: split.test.map(\.id)))
        #expect(PersonalCategoryPolicy.split(rows, kind: 1) == nil)
        let rare = (0..<15).map { sample($0, label: $0 < 2 ? "rare" : "common") }
        #expect(PersonalCategoryPolicy.split(rare, kind: 0) == nil)
    }

    @Test func calibrationRequiresSupportAndPrecisionAndDecisionUsesBoundaries() {
        let calibration = (0..<5).map { _ in score(0.9) } + [score(0.7, correct: false)]
        #expect(PersonalCategoryPolicy.threshold(calibration: calibration, exampleCount: 50) == 0.9)
        #expect(PersonalCategoryPolicy.threshold(calibration: Array(calibration.prefix(4)), exampleCount: 50) == nil)
        #expect(PersonalCategoryPolicy.threshold(calibration: [], exampleCount: 49) == 1)
        #expect(PersonalCategoryPolicy.accepts(score(0.9, similarity: 0.82, margin: 0.25), threshold: 0.9))
        #expect(!PersonalCategoryPolicy.accepts(score(0.899), threshold: 0.9))
        #expect(!PersonalCategoryPolicy.accepts(score(1, similarity: 0.819), threshold: 0.9))
        #expect(!PersonalCategoryPolicy.accepts(score(1, margin: 0.249), threshold: 0.9))
        #expect(!PersonalCategoryPolicy.accepts(score(.nan), threshold: 0.9))
    }

    @Test func evaluationIncludesAbstentionsAndBothBaselines() {
        let training = (0..<9).map { sample($0) }
        let test = [sample(10), sample(11), PersonalCategoryExample(id: UUID(), text: "unseenshop",
            label: "groceries", kind: 0, date: .now)]
        let scores = [PersonalCategoryScore(expected: "groceries", predicted: "groceries", confidence: 1, margin: 1, similarity: 1),
                      PersonalCategoryScore(expected: "dining", predicted: "dining", confidence: 1, margin: 1, similarity: 1),
                      PersonalCategoryScore(expected: "groceries", predicted: "dining", confidence: 1, margin: 1, similarity: 0.2)]
        let result = PersonalCategoryPolicy.metrics(scores: scores, threshold: 1, training: training, test: test)
        #expect(result.total == 3)
        #expect(result.suggested == 2)
        #expect(result.correct == 2)
        #expect(result.exactSuggested == 2)
        #expect(result.exactCorrect == 2)
        #expect(result.majorityCorrect == 2)
        #expect(result.accuracy == 1)
    }

    @Test func replacementCannotRegressOrActivateWithoutTestSuggestions() {
        let previous = PersonalCategoryMetrics(total: 10, suggested: 10, correct: 10)
        #expect(!PersonalCategoryPolicy.canActivate(.init(total: 10, suggested: 10, correct: 9), previous: previous))
        #expect(!PersonalCategoryPolicy.canActivate(.init(total: 10), previous: nil))
        #expect(PersonalCategoryPolicy.canActivate(.init(total: 10, suggested: 9, correct: 9), previous: previous))
        #expect(!PersonalCategoryPolicy.canActivate(.init(total: 9, suggested: 9, correct: 9), previous: previous))
    }

    @Test func sourceEditsDeletionsAndExclusionsInvalidateButNewExamplesDoNot() {
        let original = sample(0)
        let archive = PersonalCategoryArchive(sourceExamples: [original])
        #expect(archive.isValid(for: [original, sample(1)]))
        #expect(!archive.isValid(for: []))
        let edited = PersonalCategoryExample(id: original.id, text: original.text,
            label: "different", kind: original.kind, date: original.date)
        #expect(!archive.isValid(for: [edited]))
    }

    @Test func clearingInvalidModelsRemovesSourcesAndPreservesOnlyMetrics() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ledgerly-archive-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let version = UUID()
        let record = PersonalCategoryModelRecord(version: version, kind: 0, threshold: 1, training: [sample(0)])
        let attempt = PersonalCategoryAttempt(id: version, date: .now, kind: 0, exampleCount: 15,
            trainingCount: 9, calibrationCount: 3, threshold: 1, metrics: .init(total: 3, suggested: 3, correct: 3),
            activated: true, reason: "Synthetic test")
        let archive = PersonalCategoryArchive(models: [record], sourceExamples: record.training,
            attempts: [attempt], calibratedEstimateVersions: [version])
        try PersonalCategoryStorage.save(archive, to: folder)
        let modelFolder = folder.appendingPathComponent(version.uuidString + ".mlmodelc")
        try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)
        let cleared = try PersonalCategoryStorage.invalidate(archive, at: folder)
        #expect(cleared.models.isEmpty && cleared.sourceExamples.isEmpty)
        #expect(cleared.calibratedEstimateVersions == nil)
        #expect(try PersonalCategoryStorage.load(from: folder).calibratedEstimateVersions == nil)
        #expect(try PersonalCategoryStorage.load(from: folder).attempts.count == 1)
        #expect(!FileManager.default.fileExists(atPath: modelFolder.path))
    }

    @Test func actualCoreMLUpdatePredictsAndReloadsFromDisk() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Ledgerly IOS App/Ledgerly IOS App/Assets/PersonalCategorySeed.mlmodel")
        let compiled = try await MLModel.compileModel(at: source)
        defer { try? FileManager.default.removeItem(at: compiled) }
        let rows = (0..<20).map { index in
            var row = sample(index)
            if index.isMultiple(of: 3) { row.correctionDate = row.date }
            return row
        }
        let result = try await PersonalCategoryTrainer.train(examples: rows, seed: compiled, previous: [:])
        defer { try? FileManager.default.removeItem(at: result.staging) }
        #expect(result.attempts.count == 1)
        let attempt = try #require(result.attempts.first)
        #expect(attempt.activated)
        #expect(attempt.trainingCount == 12)
        #expect(attempt.correctedTrainingExamples == 4)
        #expect(attempt.weightedTrainingRows == 16)
        #expect(attempt.metrics.total == 4 && attempt.metrics.correct == 4)
        #expect(attempt.metrics.perCategory?.count == 2)
        #expect(attempt.metrics.perCategory?.allSatisfy { $0.precision == 1 && $0.recall == 1 } == true)
        #expect(attempt.metrics.reliability?.all.count == 4)
        #expect(attempt.metrics.reliability?.shown.correct == 4)
        #expect(attempt.calibrationCheck?.status == .insufficientCalibration)
        #expect(attempt.calibrationCheck?.calibrationCount == 4)
        #expect(attempt.calibrationCheck?.testCount == 4)
        let predictor = try #require(result.predictors[0])
        #expect(predictor.record.correctionWeightingVersion == 1)
        #expect(Set(predictor.record.training.map(\.id)).count == 12)
        #expect(try predictor.score(text: "keellssupermarket").independentSupport == 6)
        #expect(try predictor.score(text: "keellssupermarket").predicted == "groceries")
        let unseen = try predictor.score(text: "unrelateddigitalphotography")
        #expect(!PersonalCategoryPolicy.accepts(unseen, threshold: predictor.record.threshold))
        let archive = PersonalCategoryArchive(models: result.models, sourceExamples: rows, attempts: result.attempts)
        let reloaded = try PersonalCategoryTrainer.predictors(archive: archive, folder: result.staging)
        #expect(try reloaded[0]?.score(text: "baristacoffee").predicted == "dining")

        // Later labels deliberately disagree with the old pattern. Neither a bad new model
        // nor an old model's low score may bypass the absolute precision target.
        let contradictory = (20..<30).map { sample($0, label: $0.isMultiple(of: 2) ? "dining" : "groceries") }
        let rejected = try await PersonalCategoryTrainer.train(examples: rows + contradictory,
            seed: compiled, previous: reloaded)
        defer { try? FileManager.default.removeItem(at: rejected.staging) }
        #expect(rejected.models.isEmpty)
        #expect(rejected.attempts.first?.activated == false)
        #expect(try reloaded[0]?.score(text: "keellssupermarket").predicted == "groceries")

        // A repeated correction is still only one independent similar transaction.
        let rareA = UUID()
        let rareB = UUID()
        let rareRows = (0..<15).map { index in
            var row = PersonalCategoryExample(id: UUID(),
                text: index == 0 || index == 14 ? "rareobservatory" : index < 4 ? "mountainclimbing" : "baristacoffee",
                label: (index < 4 || index == 14 ? rareA : rareB).uuidString, kind: 0,
                date: Date(timeIntervalSince1970: Double(1_700_000_000 + index * 86_400)))
            if index == 0 { row.correctionDate = row.date }
            return row
        }
        let rareResult = try await PersonalCategoryTrainer.train(examples: rareRows, seed: compiled, previous: [:])
        defer { try? FileManager.default.removeItem(at: rareResult.staging) }
        let rarePredictor = try #require(rareResult.predictors[0])
        let rareEvaluation = try rarePredictor.evaluate(text: "rareobservatory")
        let rareScore = rareEvaluation.score
        #expect(rareScore.predicted == rareA.uuidString)
        #expect(rareScore.independentSupport == 1)
        #expect(!PersonalCategoryPolicy.accepts(rareScore, threshold: rarePredictor.record.threshold))
        let alternatives = CategorySuggestionPolicy.alternatives(scores: rareEvaluation.ranked,
            title: "Rare Observatory", kind: .expense,
            activeCategories: [.init(id: rareA, name: "Education", kind: .expense,
                isSystem: true, isArchived: false, sortIndex: 0)], source: .personalModel,
            modelVersion: rarePredictor.record.version)
        #expect(alternatives.map(\.id) == [rareA])
        #expect(alternatives.first?.modelVersion == rarePredictor.record.version)
    }
}
