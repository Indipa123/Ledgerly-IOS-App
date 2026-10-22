import Foundation
import Testing
@testable import LedgerlyDomain

struct PersonalCategoryReliabilityTests {
    private func score(_ value: Double, predicted: String? = "a", similarity: Double = 1) -> PersonalCategoryScore {
        .init(expected: "not-used", predicted: predicted, confidence: value, margin: 1, similarity: similarity)
    }

    private func metrics(_ scores: [PersonalCategoryScore], count: Int? = nil) -> PersonalCategoryMetrics {
        let test = (0..<(count ?? scores.count)).map { _ in
            PersonalCategoryExample(id: UUID(), text: "test", label: "a", kind: 0, date: .now)
        }
        return PersonalCategoryPolicy.metrics(scores: scores, threshold: 0.9, training: [], test: test)
    }

    @Test func scoreBoundariesUseHalfOpenBinsAndIncludeOneInLastBin() throws {
        let report = try #require(metrics([0, 0.19999, 0.2, 0.4, 0.6, 0.8, 1].map { score($0) }).reliability)
        #expect(report.all.bins.map(\.count) == [2, 1, 1, 1, 2])
        #expect(report.all.count == 7 && report.unscored == 0)
        #expect(report.shown.count == 1 && report.shown.bins.last?.count == 1)
    }

    @Test func gapIsWeightedBySampleCountRatherThanAveragingNonemptyBinsEqually() throws {
        let report = try #require(metrics([score(0.2), score(0.2, predicted: "b"), score(0.9)]).reliability)
        #expect(abs((report.all.meanScore ?? -1) - 1.3 / 3) < 0.000_001)
        #expect(report.all.accuracy == 2.0 / 3)
        #expect(abs((report.all.binnedGap ?? -1) - 0.7 / 3) < 0.000_001)
        #expect(abs((report.shown.binnedGap ?? -1) - 0.1) < 0.000_001)
    }

    @Test func confidentButRejectedWrongPredictionStaysInAllScoresOnly() throws {
        let result = metrics([score(1, predicted: "b", similarity: 0.1)])
        let report = try #require(result.reliability)
        #expect(report.all.count == 1 && report.all.correct == 0 && report.all.binnedGap == 1)
        #expect(report.shown.count == 0 && report.shown.binnedGap == nil)
        #expect(result.suggested == report.shown.count && result.correct == report.shown.correct)
    }

    @Test func invalidMissingAndAbsentLabelScoresAreReportedWithoutNaNOrFakeBins() throws {
        let result = metrics([score(.nan), score(.infinity), score(-0.1), score(1.1),
            score(0.9, predicted: nil), score(0.5)], count: 7)
        let report = try #require(result.reliability)
        #expect(report.all.count == 1 && report.unscored == 6)
        #expect(report.all.meanScore == 0.5 && report.shown.count == 0)
        #expect(report.all.bins.filter { $0.count > 0 }.count == 1)
    }

    @Test func emptyEvaluationHasNoAccuracyOrGap() throws {
        let report = try #require(metrics([]).reliability)
        #expect(report.all.count == 0 && report.all.bins.count == 5)
        #expect(report.all.meanScore == nil && report.all.accuracy == nil && report.all.binnedGap == nil)
        #expect(report.all.bins.allSatisfy { $0.accuracy == nil && $0.meanScore == nil })
    }

    @Test func reliabilityPersistsAndOlderMetricsHaveNoInventedReport() throws {
        let result = metrics([score(0.2), score(1, predicted: "b")])
        let reopened = try JSONDecoder().decode(PersonalCategoryMetrics.self, from: JSONEncoder().encode(result))
        #expect(reopened.reliability == result.reliability)
        let legacy = Data(#"{"total":2,"suggested":1,"correct":0,"exactSuggested":0,"exactCorrect":0,"majorityCorrect":1}"#.utf8)
        #expect(try JSONDecoder().decode(PersonalCategoryMetrics.self, from: legacy).reliability == nil)
    }
}
