import Foundation
import Testing
@testable import LedgerlyDomain

struct PlacePromptFeedbackTests {
    private let placeID = UUID()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func visit(at date: Date, abandoned: Bool = false) -> PlaceVisit {
        PlaceVisit(id: UUID(), placeID: placeID, placeName: "Groceries", enteredAt: date,
                   isAbandoned: abandoned)
    }

    @Test func mutesAfterThreeDifferentDismissedVisits() {
        var state = PlacePromptDismissalState()
        for index in 0..<3 {
            let entered = start.addingTimeInterval(Double(index) * 3_600)
            let counted = state.dismiss(visit: visit(at: entered), at: entered.addingTimeInterval(60))
            #expect(counted)
            #expect(state.streak == index + 1)
            #expect(state.isAutomaticallyMuted == (index == 2))
        }
        let afterMute = state.dismiss(visit: visit(at: start.addingTimeInterval(4 * 3_600)),
                                      at: start.addingTimeInterval(4 * 3_600 + 60))
        #expect(!afterMute)
        #expect(state.streak == 3)
    }

    @Test func aNotificationAndCardDismissalCountOnlyOnceAcrossRestarts() throws {
        var state = PlacePromptDismissalState()
        let first = visit(at: start)
        let firstCounted = state.dismiss(visit: first, at: start.addingTimeInterval(10))
        #expect(firstCounted)
        state = try JSONDecoder().decode(PlacePromptDismissalState.self, from: JSONEncoder().encode(state))
        let duplicate = state.dismiss(visit: first, at: start.addingTimeInterval(20))
        #expect(!duplicate)
        #expect(state.streak == 1)
    }

    @Test func resumingRejectsOldCallbacksAndStartsANewStreak() {
        var state = PlacePromptDismissalState()
        let old = visit(at: start)
        let reset = start.addingTimeInterval(300)
        _ = state.dismiss(visit: old, at: start.addingTimeInterval(30))
        state.reset(at: reset)
        #expect(state.streak == 0)
        #expect(!state.isAutomaticallyMuted)
        let oldCounted = state.dismiss(visit: old, at: reset.addingTimeInterval(30))
        let boundaryCounted = state.dismiss(visit: visit(at: reset), at: reset.addingTimeInterval(30))
        let newCounted = state.dismiss(visit: visit(at: reset.addingTimeInterval(1)),
                                        at: reset.addingTimeInterval(30))
        #expect(!oldCounted)
        #expect(!boundaryCounted)
        #expect(newCounted)
        #expect(state.streak == 1)
    }

    @Test func oldAbandonedAndFutureVisitsCannotCauseAutomaticMuting() {
        var state = PlacePromptDismissalState()
        let abandoned = state.dismiss(visit: visit(at: start, abandoned: true), at: start.addingTimeInterval(60))
        let expired = state.dismiss(visit: visit(at: start),
                                     at: start.addingTimeInterval(PlaceVisitPolicy.abandonedAfter))
        let future = state.dismiss(visit: visit(at: start.addingTimeInterval(60)), at: start)
        #expect(!abandoned)
        #expect(!expired)
        #expect(!future)
        #expect(state.streak == 0)
    }

    @Test func enablingTheFeatureDoesNotCountEarlierNotifications() {
        var state = PlacePromptDismissalState()
        let enabled = start.addingTimeInterval(60)
        let beforeEnabled = state.dismiss(visit: visit(at: start), at: start.addingTimeInterval(120), enabledAfter: enabled)
        let afterEnabled = state.dismiss(visit: visit(at: enabled.addingTimeInterval(1)),
                                          at: start.addingTimeInterval(120), enabledAfter: enabled)
        #expect(!beforeEnabled)
        #expect(afterEnabled)
    }

    @Test func recordingAnExpenseResetsAutomaticMutingAndSurvivesPersistence() throws {
        var state = PlacePromptDismissalState()
        for second in 0..<3 {
            _ = state.dismiss(visit: visit(at: start.addingTimeInterval(Double(second))),
                                at: start.addingTimeInterval(30))
        }
        #expect(state.isAutomaticallyMuted)
        state.reset(at: start.addingTimeInterval(60))
        let restored = try JSONDecoder().decode(PlacePromptDismissalState.self, from: JSONEncoder().encode(state))
        #expect(!restored.isAutomaticallyMuted)
        #expect(restored.streak == 0)
        #expect(restored.acceptingVisitsAfter == start.addingTimeInterval(60))
    }

    @Test func onlyNewExpenseAttachmentsResetAPlacesFeedback() {
        let otherPlace = UUID()
        let location = LedgerLocation(placeID: placeID, name: "Shop", latitude: 7, longitude: 80)
        let expense = LedgerEntry(id: UUID(), kind: .expense, amount: 100, title: "", category: "Groceries",
                                  date: start, note: "", location: location)
        let income = LedgerEntry(id: UUID(), kind: .income, amount: 100, title: "", category: "Salary",
                                 date: start, note: "", location: location)
        #expect(PlacePromptFeedbackPolicy.newlyRecordedPlaceIDs(previous: [], current: [expense, income]) == [placeID])
        #expect(PlacePromptFeedbackPolicy.newlyRecordedPlaceIDs(previous: [expense], current: [expense, income]).isEmpty)
        var edited = expense
        edited.location = LedgerLocation(placeID: otherPlace, name: "Other shop", latitude: 7, longitude: 80)
        #expect(PlacePromptFeedbackPolicy.newlyRecordedPlaceIDs(previous: [expense], current: [edited]) == [otherPlace])
        #expect(PlacePromptFeedbackPolicy.newlyRecordedPlaceIDs(previous: [expense], current: []).isEmpty)
    }
}
