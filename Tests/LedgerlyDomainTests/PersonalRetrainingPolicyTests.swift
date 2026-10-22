import Foundation
import Testing
@testable import LedgerlyDomain

struct PersonalRetrainingPolicyTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private func state() -> PersonalRetrainingState {
        .init(enabled: true, lastAttemptAt: date, categoryRevision: "same")
    }

    @Test func firstRunRequiresOptInAndTrainableData() {
        #expect(PersonalRetrainingPolicy.reason(state: .init(), exampleIDs: [], revision: "same", hasTrainableData: true) == nil)
        #expect(PersonalRetrainingPolicy.reason(state: .init(enabled: true), exampleIDs: [], revision: "same", hasTrainableData: false) == nil)
        #expect(PersonalRetrainingPolicy.reason(state: .init(enabled: true), exampleIDs: [], revision: "same", hasTrainableData: true) == .firstModel)
    }

    @Test func tenNewExamplesExcludeAlreadyCheckedIDs() {
        let old = UUID()
        var state = state()
        state.checkpointIDs = [old]
        var ids = Set((0..<9).map { _ in UUID() })
        ids.insert(old)
        #expect(PersonalRetrainingPolicy.reason(state: state, exampleIDs: ids, revision: "same", hasTrainableData: true, now: date) == nil)
        ids.insert(UUID())
        #expect(PersonalRetrainingPolicy.reason(state: state, exampleIDs: ids, revision: "same", hasTrainableData: true, now: date) == .newExamples)
    }

    @Test func correctionsCountDistinctCurrentlyEligibleTransactions() {
        let ids = (0..<3).map { _ in UUID() }
        var state = state()
        state.correctionIDs = [ids[0]]
        for _ in 0..<5 { state.correctionIDs.insert(ids[0]) }
        #expect(PersonalRetrainingPolicy.reason(state: state, exampleIDs: Set(ids), revision: "same", hasTrainableData: true, now: date) == nil)
        state.correctionIDs = Set(ids)
        #expect(PersonalRetrainingPolicy.reason(state: state, exampleIDs: Set(ids), revision: "same", hasTrainableData: true, now: date) == .corrections)
        #expect(PersonalRetrainingPolicy.reason(state: state, exampleIDs: Set(ids.prefix(2)), revision: "same", hasTrainableData: true, now: date) == nil)
    }

    @Test func weeklyBoundaryRequiresNewDataAndDoesNotFireForBackwardsClock() {
        let state = state()
        let new: Set<UUID> = [UUID()]
        #expect(PersonalRetrainingPolicy.reason(state: state, exampleIDs: new, revision: "same", hasTrainableData: true,
            now: date.addingTimeInterval(7 * 86_400 - 1)) == nil)
        #expect(PersonalRetrainingPolicy.reason(state: state, exampleIDs: new, revision: "same", hasTrainableData: true,
            now: date.addingTimeInterval(7 * 86_400)) == .weekly)
        #expect(PersonalRetrainingPolicy.reason(state: state, exampleIDs: [], revision: "same", hasTrainableData: true,
            now: date.addingTimeInterval(30 * 86_400)) == nil)
        #expect(PersonalRetrainingPolicy.reason(state: state, exampleIDs: new, revision: "same", hasTrainableData: true,
            now: date.addingTimeInterval(-1)) == nil)
    }

    @Test func categoryRevisionIsStableAndChangesTriggerOnce() {
        let revision = PersonalRetrainingPolicy.revision(["a|Food|false", "b|Rent|false"])
        #expect(revision == PersonalRetrainingPolicy.revision(["b|Rent|false", "a|Food|false"]))
        #expect(revision != PersonalRetrainingPolicy.revision(["a|Food|true", "b|Rent|false"]))
        var state = state()
        #expect(PersonalRetrainingPolicy.reason(state: state, exampleIDs: [], revision: revision, hasTrainableData: true, now: date) == .categoriesChanged)
        state.completed(exampleIDs: [], revision: revision, at: date)
        #expect(PersonalRetrainingPolicy.reason(state: state, exampleIDs: [], revision: revision, hasTrainableData: true, now: date) == nil)
    }

    @Test func completedOrFailedAttemptResetsCountersWithoutDisablingPreference() {
        let ids = Set((0..<10).map { _ in UUID() })
        var state = state()
        state.correctionIDs = Set(ids.prefix(3))
        state.completed(exampleIDs: ids, revision: "same", at: date)
        #expect(state.enabled)
        #expect(state.correctionIDs.isEmpty)
        #expect(state.checkpointIDs == ids)
        #expect(PersonalRetrainingPolicy.reason(state: state, exampleIDs: ids, revision: "same", hasTrainableData: true,
            now: date.addingTimeInterval(20 * 86_400)) == nil)
    }

    @Test func automationPersistsAndOlderArchivesRemainReadable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ledgerly-schedule-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let legacy = Data(#"{"schema":1,"models":[],"sourceExamples":[],"attempts":[]}"#.utf8)
        let old = try JSONDecoder().decode(PersonalCategoryArchive.self, from: legacy)
        #expect(old.automation == nil)
        var saved = old
        var state = state()
        state.correctionIDs = [UUID()]
        state.checkpointIDs = [UUID()]
        saved.automation = state
        try PersonalCategoryStorage.save(saved, to: folder)
        #expect(try PersonalCategoryStorage.load(from: folder).automation == state)
        #expect(try PersonalCategoryStorage.load(from: folder.appendingPathComponent("another-account")).automation == nil)
    }
}
