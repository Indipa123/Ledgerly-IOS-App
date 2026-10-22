import Foundation
import Testing
@testable import LedgerlyDomain

struct PersonalCategoryMetricsTests {
    private func example(_ label: String) -> PersonalCategoryExample {
        .init(id: UUID(), text: "shop" + label, label: label, kind: 0, date: .now)
    }

    private func score(_ label: String?, confidence: Double = 1) -> PersonalCategoryScore {
        .init(expected: "unused", predicted: label, confidence: confidence, margin: 1, similarity: 1)
    }

    @Test func perCategoryIncludesWrongSuggestionsAbstentionsAndUnseenLabels() throws {
        let training = ["a", "a", "a", "b", "b", "b", "c", "c", "c"].map(example)
        let test = ["a", "a", "a", "b", "b", "d"].map(example)
        let result = PersonalCategoryPolicy.metrics(scores: [
            score("a"), score("b"), score("a", confidence: 0.5), score("a"), score("b"), score(nil)
        ], threshold: 0.9, training: training, test: test)
        #expect(result.total == 6 && result.suggested == 4 && result.correct == 2)
        let rows = try #require(result.perCategory)
        #expect(rows.map(\.label) == ["a", "b", "c", "d"])
        let a = try #require(rows.first { $0.label == "a" })
        #expect(a.training == 3 && a.actual == 3 && a.predicted == 2 && a.correct == 1)
        #expect(a.precision == 0.5 && a.recall == 1.0 / 3.0)
        #expect(a.abstained == 1 && a.confusions == ["b": 1])
        let b = try #require(rows.first { $0.label == "b" })
        #expect(b.precision == 0.5 && b.recall == 0.5 && b.abstained == 0)
        #expect(b.confusions == ["a": 1])
        let c = try #require(rows.first { $0.label == "c" })
        #expect(c.actual == 0 && c.precision == nil && c.recall == nil)
        let d = try #require(rows.first { $0.label == "d" })
        #expect(d.training == 0 && d.actual == 1 && d.recall == 0 && d.precision == nil && d.abstained == 1)
        #expect(rows.reduce(0) { $0 + $1.correct } == result.correct)
        #expect(rows.reduce(0) { $0 + $1.predicted } == result.suggested)
        #expect(rows.reduce(0) { $0 + $1.abstained } == result.total - result.suggested)
    }

    @Test func missingScoresAreAbstentionsAndUnexpectedPredictedClassesAreCounted() throws {
        let result = PersonalCategoryPolicy.metrics(scores: [score("unexpected")], threshold: 0.9,
            training: [], test: [example("a"), example("a")])
        let rows = try #require(result.perCategory)
        let actual = try #require(rows.first { $0.label == "a" })
        #expect(actual.actual == 2 && actual.abstained == 1 && actual.recall == 0)
        #expect(actual.confusions == ["unexpected": 1])
        let predicted = try #require(rows.first { $0.label == "unexpected" })
        #expect(predicted.predicted == 1 && predicted.precision == 0 && predicted.recall == nil)
    }

    @Test func olderMetricsDecodeWithoutInventingCategoryResults() throws {
        let json = Data(#"{"total":5,"suggested":2,"correct":1,"exactSuggestedCount":0,"exactSuggested":0,"exactCorrect":0,"majorityCorrect":2}"#.utf8)
        let decoded = try JSONDecoder().decode(PersonalCategoryMetrics.self, from: json)
        #expect(decoded.total == 5 && decoded.correct == 1 && decoded.perCategory == nil)
    }

    @Test func breakdownAndZeroDenominatorsSurvivePersistence() throws {
        let report = PersonalCategoryPolicy.metrics(scores: [], threshold: 1,
            training: [example("a")], test: [])
        let data = try JSONEncoder().encode(report)
        let reopened = try JSONDecoder().decode(PersonalCategoryMetrics.self, from: data)
        #expect(reopened.perCategory == report.perCategory)
        #expect(reopened.perCategory?.first?.precision == nil)
        #expect(reopened.perCategory?.first?.recall == nil)
        #expect(reopened.coverage == 0 && reopened.accuracy == nil)
    }
}
