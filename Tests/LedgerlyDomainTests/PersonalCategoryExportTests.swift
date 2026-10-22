import Foundation
import Testing
@testable import LedgerlyDomain

struct PersonalCategoryExportTests {
    private let a = UUID().uuidString
    private let b = UUID().uuidString

    private func attempt() -> PersonalCategoryAttempt {
        var reliability = PersonalCategoryReliabilityReport()
        for correct in [true, false, true] {
            reliability.all.record(score: 1, correct: correct)
            reliability.shown.record(score: 1, correct: correct)
        }
        reliability.all.record(score: 0.3, correct: false)
        let metrics = PersonalCategoryMetrics(total: 4, suggested: 3, correct: 2,
            exactSuggested: 2, exactCorrect: 1, majorityCorrect: 2,
            perCategory: [
                .init(label: a, training: 6, actual: 2, predicted: 1, correct: 1, abstained: 0,
                      confusions: [b: 1]),
                .init(label: b, training: 6, actual: 2, predicted: 2, correct: 1, abstained: 1)
            ], reliability: reliability)
        return .init(id: UUID(), date: Date(timeIntervalSince1970: 1_700_000_000), kind: 0,
            exampleCount: 20, trainingCount: 12, calibrationCount: 4, threshold: 1,
            metrics: metrics, activated: false, reason: "PRIVATE_REASON_MUST_NOT_EXPORT",
            trigger: "PRIVATE_TRIGGER_MUST_NOT_EXPORT", correctedTrainingExamples: 3, weightedTrainingRows: 15)
    }

    @Test func defaultExportPreservesMetricsWithoutNamesRawLabelsOrUnstructuredMetadata() throws {
        let saved = attempt()
        let export = PersonalCategoryEvaluationExport(attempt: saved,
            categoryNames: [a: "Private category alpha", b: "Private category beta"])
        let data = try export.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(a) && !text.contains(b))
        #expect(!text.contains("Private category alpha") && !text.contains("Private category beta"))
        #expect(!text.contains(saved.reason) && !text.contains(saved.trigger!))
        #expect(export.categoryNamesIncluded == false)
        #expect(export.summary.testTransactions == 4 && export.summary.abstentions == 1)
        #expect(export.summary.precision == 2.0 / 3.0 && export.summary.coverage == 0.75)
        #expect(export.summary.exactBaselineSuggestions == 2 && export.summary.majorityBaselineCorrect == 2)
        #expect(export.uniqueTrainingTransactions == 12 && export.weightedTrainingRows == 15)
        #expect(export.categories?.reduce(0) { $0 + ($1.trainingTransactions ?? 0) } == 12)
        #expect(export.reliability?.all.count == 4 && export.reliability?.shown.correct == 2)
        #expect(export.categories?.allSatisfy { $0.name == nil } == true)
        let roundTrip = try JSONDecoder.withISODate.decode(PersonalCategoryEvaluationExport.self, from: data)
        #expect(roundTrip.attemptID == saved.id && roundTrip.evaluatedAt == saved.date)
    }

    @Test func categoryNamesRequireOptInAndConfusionsUseOnlyReportIdentifiers() throws {
        let name = "Café \"Special\"\nCategory"
        let export = PersonalCategoryEvaluationExport(attempt: attempt(), categoryNames: [a: name],
                                                       includeCategoryNames: true)
        let decoded = try JSONDecoder.withISODate.decode(PersonalCategoryEvaluationExport.self,
                                                        from: export.jsonData())
        #expect(decoded.categories?.contains { $0.name == name } == true)
        #expect(decoded.categories?.filter { $0.name == nil }.count == 1)
        let rows = try #require(decoded.categories)
        let identifiers = Set(rows.map(\.category))
        #expect(rows.flatMap(\.confusions).allSatisfy { identifiers.contains($0.suggestedCategory) })
        #expect(rows.flatMap(\.confusions).reduce(0) { $0 + $1.count } == 1)
        #expect(!String(decoding: try export.jsonData(), as: UTF8.self).contains(b))
    }

    @Test func oldAndEmptyReportsDoNotInventBreakdownsWeightingOrPrecision() throws {
        let saved = PersonalCategoryAttempt(id: UUID(), date: .now, kind: -1, exampleCount: 0,
            trainingCount: 0, calibrationCount: 0, threshold: nil, metrics: .init(),
            activated: false, reason: "Training failed")
        let export = PersonalCategoryEvaluationExport(attempt: saved)
        let object = try #require(try JSONSerialization.jsonObject(with: export.jsonData()) as? [String: Any])
        #expect(export.transactionType == "training")
        #expect(export.categories == nil && export.reliability == nil)
        #expect(export.summary.precision == nil && export.summary.coverage == 0)
        #expect(object["categories"] == nil && object["weightedTrainingRows"] == nil)
        #expect(object["correctedTrainingTransactions"] == nil && object["reliability"] == nil)
        #expect(object["schemaVersion"] as? Int == 1)
    }

    @Test func unknownConfusionLabelsStayAnonymousAndHaveValidReportReferences() throws {
        let unknown = UUID().uuidString
        var saved = attempt()
        var metrics = saved.metrics
        metrics.perCategory = [.init(label: a, confusions: [unknown: 1])]
        saved = .init(id: saved.id, date: saved.date, kind: saved.kind, exampleCount: saved.exampleCount,
            trainingCount: saved.trainingCount, calibrationCount: saved.calibrationCount,
            threshold: saved.threshold, metrics: metrics, activated: false, reason: saved.reason)
        let export = PersonalCategoryEvaluationExport(attempt: saved)
        let rows = try #require(export.categories)
        #expect(rows.count == 2)
        #expect(rows.filter { $0.trainingTransactions == nil }.count == 1)
        #expect(rows.flatMap(\.confusions).allSatisfy { Set(rows.map(\.category)).contains($0.suggestedCategory) })
        #expect(!String(decoding: try export.jsonData(), as: UTF8.self).contains(unknown))
    }
}

private extension JSONDecoder {
    static var withISODate: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
