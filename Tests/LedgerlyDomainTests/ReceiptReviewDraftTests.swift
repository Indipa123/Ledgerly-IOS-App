import Foundation
import Testing
@testable import LedgerlyDomain

struct ReceiptReviewDraftTests {
    private let initial = Date(timeIntervalSince1970: 1_700_000_000)
    private let printed = Date(timeIntervalSince1970: 1_701_000_000)

    private var suggestions: ReceiptSuggestions {
        .init(merchant: "OCR merchant", amount: Decimal(string: "430.25"), date: printed,
              dateCandidates: [], lines: ["Synthetic receipt"], dateIncludesTime: true)
    }

    @Test func untouchedFieldsReceiveRecognition() {
        var draft = ReceiptReviewDraft(date: initial)
        draft.apply(suggestions)
        #expect(draft.merchant == "OCR merchant")
        #expect(draft.amountText == "430.25")
        #expect(draft.date == printed && draft.useDate && draft.includeTime)
    }

    @Test func typingDuringRecognitionPreservesTheExactInputAndFillsOtherFields() {
        var draft = ReceiptReviewDraft(date: initial)
        draft.setAmountText("125.")
        draft.apply(suggestions)
        #expect(draft.amountText == "125.")
        #expect(draft.merchant == "OCR merchant" && draft.date == printed)
    }

    @Test func explicitlyClearingFieldsIsNotUndoneByLateRecognition() {
        var draft = ReceiptReviewDraft(date: initial)
        draft.setMerchant("My merchant")
        draft.setMerchant("")
        draft.setAmountText("100")
        draft.setAmountText("")
        draft.apply(suggestions)
        #expect(draft.merchant.isEmpty && draft.amountText.isEmpty)
        #expect(draft.useDate && draft.date == printed)
    }

    @Test func optingOutOfTheDateIsRespectedEvenWhenRecognitionFindsOne() {
        var draft = ReceiptReviewDraft(date: initial)
        draft.setUseDate(false)
        draft.apply(suggestions)
        #expect(!draft.useDate && !draft.includeTime && draft.date == initial)
        #expect(draft.amountText == "430.25")
    }

    @Test func manualDateTimeAndChosenAmbiguousCandidateSurviveLaterSuggestions() {
        var draft = ReceiptReviewDraft(date: initial)
        draft.setDate(initial.addingTimeInterval(3600))
        draft.setUseDate(true)
        draft.setIncludeTime(false)
        draft.apply(suggestions)
        #expect(draft.date == initial.addingTimeInterval(3600) && draft.useDate && !draft.includeTime)
        let candidate = ReceiptDateCandidate(date: initial, format: "Chosen reading", timeSourceText: "11:38:06")
        draft.select(candidate)
        draft.apply(suggestions)
        #expect(draft.date == initial && draft.useDate && draft.includeTime)
    }

    @Test func noRecognizedDateNeverEnablesTimeOnItsOwn() {
        var draft = ReceiptReviewDraft(date: initial)
        draft.apply(.init(merchant: nil, amount: nil, date: nil, dateCandidates: [], lines: [], dateIncludesTime: true))
        #expect(draft.merchant.isEmpty && draft.amountText.isEmpty)
        #expect(draft.date == initial && !draft.useDate && !draft.includeTime)
    }
}
