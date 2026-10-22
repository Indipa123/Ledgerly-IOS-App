import Foundation

struct LedgerFriend: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isArchived = false
    var createdAt: Date = .now
    var updatedAt: Date = .now

    var isValid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct SplitShare: Identifiable, Equatable {
    let id: UUID
    var friendID: UUID? // nil is the user's share
    var amount: Decimal
    var settledAt: Date? = nil
}

struct SplitBill: Identifiable, Equatable {
    let id: UUID
    var entryID: UUID
    var totalAmount: Decimal
    var note: String
    var shares: [SplitShare]
    var createdAt: Date = .now
    var updatedAt: Date = .now
    var deletedAt: Date? = nil

    var ownShare: Decimal { shares.first(where: { $0.friendID == nil })?.amount ?? 0 }
    var outstanding: Decimal {
        shares.filter { $0.friendID != nil && $0.settledAt == nil }
            .reduce(.zero) { $0 + $1.amount }
    }
    var isValid: Bool {
        guard totalAmount > 0, shares.count >= 2,
              shares.filter({ $0.friendID == nil }).count == 1,
              Set(shares.compactMap(\.friendID)).count == shares.count - 1,
              shares.allSatisfy({ $0.amount >= 0 && SplitMath.cents($0.amount) != nil }) else { return false }
        return shares.reduce(Decimal.zero) { $0 + $1.amount } == totalAmount
    }
}

enum SplitMath {
    /// Strict decimal input: reject partial parses such as "25abc" or "20%".
    /// Both decimal separators are accepted, with at most two fractional digits.
    static func percentageInput(_ text: String) -> Decimal? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard normalized.range(of: #"^[0-9]+(?:\.[0-9]{1,2})?$"#,
                               options: .regularExpression) != nil,
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              value >= 0, value <= 100 else { return nil }
        return value
    }

    /// Round friends' shares down to cents; keep the remaining cents with the payer,
    /// matching the equal-split rounding rule. Decimal arithmetic avoids overflow
    /// from multiplying Int64 cents by basis points.
    static func percentage(total: Decimal, friendPercentages: [(UUID, Decimal)]) -> [SplitShare]? {
        guard let totalCents = cents(total), totalCents > 0, !friendPercentages.isEmpty,
              Set(friendPercentages.map(\.0)).count == friendPercentages.count else { return nil }
        var allocatedPercentage: Decimal = 0
        var amounts: [(UUID, Decimal)] = []
        for (friendID, percentage) in friendPercentages {
            guard percentage >= 0, percentage <= 100, cents(percentage) != nil else { return nil }
            allocatedPercentage += percentage
            guard allocatedPercentage <= 100 else { return nil }
            var rawCents = Decimal(totalCents) * percentage / 100
            var roundedCents: Decimal = 0
            NSDecimalRound(&roundedCents, &rawCents, 0, .down)
            amounts.append((friendID, roundedCents / 100))
        }
        return custom(total: total, friendAmounts: amounts)
    }

    static func cents(_ amount: Decimal) -> Int64? {
        let scaled = NSDecimalNumber(decimal: amount * 100)
        guard scaled != .notANumber, scaled.decimalValue == Decimal(scaled.int64Value) else { return nil }
        return scaled.int64Value
    }

    static func equal(total: Decimal, friendIDs: [UUID]) -> [SplitShare]? {
        guard let totalCents = cents(total), totalCents > 0,
              !friendIDs.isEmpty, Set(friendIDs).count == friendIDs.count else { return nil }
        let count = Int64(friendIDs.count + 1)
        let friendCents = totalCents / count
        let ownCents = totalCents - friendCents * Int64(friendIDs.count)
        return [SplitShare(id: UUID(), friendID: nil, amount: Decimal(ownCents) / 100)] +
            friendIDs.map { SplitShare(id: UUID(), friendID: $0,
                                       amount: Decimal(friendCents) / 100) }
    }

    static func custom(total: Decimal, friendAmounts: [(UUID, Decimal)]) -> [SplitShare]? {
        guard let totalCents = cents(total), totalCents > 0, !friendAmounts.isEmpty,
              Set(friendAmounts.map(\.0)).count == friendAmounts.count else { return nil }
        let values = friendAmounts.map { cents($0.1) }
        guard values.allSatisfy({ $0 != nil }),
              values.compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { return nil }
        let friendCents = values.compactMap { $0 }.reduce(Int64.zero, +)
        guard friendCents <= totalCents else { return nil }
        return [SplitShare(id: UUID(), friendID: nil,
                           amount: Decimal(totalCents - friendCents) / 100)] +
            friendAmounts.map { SplitShare(id: UUID(), friendID: $0.0, amount: $0.1) }
    }
}
