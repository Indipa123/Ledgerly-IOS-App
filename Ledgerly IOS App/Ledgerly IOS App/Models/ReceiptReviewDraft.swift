import Foundation

/// Recognition may finish after the user has started correcting the receipt.
/// A manual edit, including clearing a field, takes priority over late OCR.
nonisolated struct ReceiptReviewDraft {
    private(set) var merchant = ""
    private(set) var amountText = ""
    private(set) var date: Date
    private(set) var useDate = false
    private(set) var includeTime = false
    private var editedMerchant = false
    private var editedAmount = false
    private var editedDate = false

    init(date: Date = .now) { self.date = date }

    mutating func setMerchant(_ value: String) { merchant = value; editedMerchant = true }
    mutating func setAmountText(_ value: String) { amountText = value; editedAmount = true }
    mutating func setDate(_ value: Date) { date = value; editedDate = true }
    mutating func setUseDate(_ value: Bool) { useDate = value; editedDate = true }
    mutating func setIncludeTime(_ value: Bool) { includeTime = value; editedDate = true }

    mutating func select(_ candidate: ReceiptDateCandidate) {
        date = candidate.date
        useDate = true
        includeTime = candidate.includesTime
        editedDate = true
    }

    mutating func apply(_ suggestions: ReceiptSuggestions) {
        if !editedMerchant { merchant = suggestions.merchant ?? "" }
        if !editedAmount {
            amountText = suggestions.amount.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        }
        if !editedDate {
            if let suggestedDate = suggestions.date { date = suggestedDate }
            useDate = suggestions.date != nil
            includeTime = useDate && suggestions.dateIncludesTime
        }
    }
}
