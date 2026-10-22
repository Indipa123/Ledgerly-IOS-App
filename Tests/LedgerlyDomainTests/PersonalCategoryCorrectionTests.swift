import Foundation
import Testing
@testable import LedgerlyDomain

@MainActor
struct PersonalCategoryCorrectionTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func onlyCurrentExplicitLocalFeedbackReceivesCorrectionWeight() {
        let categoryID = UUID()
        var entry = LedgerEntry(id: UUID(), kind: .expense, amount: 100, title: "Example",
            category: "Groceries", date: now, note: "", categoryID: categoryID)
        #expect(CategoryCorrectionPolicy.date(for: entry) == nil)
        entry.categorySuggestion = .init(source: .model, suggestedCategoryID: UUID(),
            suggestedCategoryName: "Shopping", savedCategoryID: categoryID,
            savedCategoryName: "Groceries", kind: 0, recordedAt: now)
        #expect(CategoryCorrectionPolicy.date(for: entry) == now)
        let selection = CategorySelection(categoryID: categoryID, name: "Groceries", kind: 0)
        let before = CategorySelection(categoryID: UUID(), name: "Shopping", kind: 0)
        entry.categoryChanges = [.init(id: UUID(), recordedAt: now.addingTimeInterval(1),
            from: before, to: selection, origin: .cloudUpdate)]
        #expect(CategoryCorrectionPolicy.date(for: entry) == nil)
        entry.categoryChanges.append(.init(id: UUID(), recordedAt: now.addingTimeInterval(2),
            from: before, to: selection, origin: .thisDevice))
        #expect(CategoryCorrectionPolicy.date(for: entry) == now.addingTimeInterval(2))
        entry.categoryID = UUID()
        #expect(CategoryCorrectionPolicy.date(for: entry) == nil)
    }

    @Test func laterCorrectionsCannotEnterEarlierTrainingAndOnlyTrainingRowsRepeat() throws {
        let rows = (0..<20).map { index in
            PersonalCategoryExample(id: UUID(), text: "example\(index)", label: index.isMultiple(of: 2) ? "a" : "b",
                kind: 0, date: now.addingTimeInterval(Double(index)))
        }
        var corrected = rows
        corrected[0].correctionDate = now.addingTimeInterval(100)
        corrected[1].correctionDate = corrected[1].date
        let split = try #require(PersonalCategoryPolicy.split(corrected, kind: 0))
        #expect(!split.training.contains { $0.id == rows[0].id })
        #expect(split.test.contains { $0.id == rows[0].id })
        let updateRows = PersonalCategoryPolicy.updateExamples(for: split)
        #expect(updateRows.count == split.training.count + 1)
        #expect(updateRows.filter { $0.id == rows[1].id }.count == 2)
        #expect(Set(updateRows.map(\.id)).isDisjoint(with: split.test.map(\.id)))
        #expect(Set(updateRows.map(\.id)).isDisjoint(with: split.calibration.map(\.id)))
        #expect(split.calibration.count == 4 && split.test.count == 4)
        #expect(PersonalCategoryPolicy.split(Array(corrected.prefix(14)), kind: 0) == nil)
    }

    @Test func repeatedRowsCannotSupplyIndependentSupportOrInflateMetrics() {
        let unsupported = PersonalCategoryScore(expected: "a", predicted: "a", confidence: 1,
            margin: 1, similarity: 1, independentSupport: 1)
        let supported = PersonalCategoryScore(expected: "a", predicted: "a", confidence: 1,
            margin: 1, similarity: 1, independentSupport: 2)
        #expect(!PersonalCategoryPolicy.accepts(unsupported, threshold: 1))
        #expect(PersonalCategoryPolicy.accepts(supported, threshold: 1))
        let sample = PersonalCategoryExample(id: UUID(), text: "example", label: "a", kind: 0,
                                            date: now, correctionDate: now)
        let report = PersonalCategoryPolicy.metrics(scores: [unsupported], threshold: 1,
            training: [sample], test: [sample])
        #expect(report.total == 1 && report.suggested == 0)
        #expect(report.perCategory?.first?.training == 1)
        #expect(report.reliability?.all.count == 1 && report.reliability?.shown.count == 0)
    }

    @Test func oldExamplesDecodeUnweightedAndCorrectionChangesInvalidateArchives() throws {
        let id = UUID()
        let old = Data("""
        {"id":"\(id)","text":"example","label":"a","kind":0,"date":100}
        """.utf8)
        let example = try JSONDecoder().decode(PersonalCategoryExample.self, from: old)
        #expect(example.correctionDate == nil && example.availableAt == example.date)
        var corrected = example
        corrected.correctionDate = now
        let archive = PersonalCategoryArchive(sourceExamples: [example])
        #expect(!archive.isValid(for: [corrected]))
        #expect(try JSONDecoder().decode(PersonalCategoryExample.self,
                                        from: JSONEncoder().encode(corrected)) == corrected)
    }
}
