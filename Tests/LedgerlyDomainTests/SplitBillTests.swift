import Foundation
import Testing
@testable import LedgerlyDomain

@MainActor
struct SplitBillTests {
    @Test func percentagesLeaveUnallocatedShareWithPayer() throws {
        let friends = [UUID(), UUID()]
        let shares = try #require(SplitMath.percentage(total: 2_000,
            friendPercentages: [(friends[0], Decimal(25)), (friends[1], Decimal(string: "12.5")!)]))
        #expect(shares.map(\.amount) == [1_250, 500, 250])
        let bill = SplitBill(id: UUID(), entryID: UUID(), totalAmount: 2_000, note: "", shares: shares)
        #expect(bill.isValid)
        #expect(bill.outstanding == 750)
    }

    @Test func percentagesPreserveTotalWhenRoundingSmallAmounts() throws {
        let friends = [UUID(), UUID(), UUID()]
        let shares = try #require(SplitMath.percentage(total: Decimal(string: "0.05")!,
            friendPercentages: [(friends[0], Decimal(string: "33.33")!),
                                (friends[1], Decimal(string: "33.33")!),
                                (friends[2], Decimal(string: "33.34")!)]))
        #expect(shares.map(\.amount) == [Decimal(string: "0.02")!,
                                       Decimal(string: "0.01")!,
                                       Decimal(string: "0.01")!,
                                       Decimal(string: "0.01")!])
        #expect(shares.reduce(Decimal.zero) { $0 + $1.amount } == Decimal(string: "0.05"))
        let full = try #require(SplitMath.percentage(total: 100, friendPercentages: [(friends[0], Decimal(100))]))
        #expect(full.map(\.amount) == [0, 100])
        let zero = try #require(SplitMath.percentage(total: 100, friendPercentages: [(friends[0], Decimal(0))]))
        #expect(zero.map(\.amount) == [100, 0])
    }

    @Test func percentagesRejectInvalidAllocations() {
        let a = UUID(), b = UUID()
        #expect(SplitMath.percentage(total: 100, friendPercentages: []) == nil)
        #expect(SplitMath.percentage(total: 100, friendPercentages: [(a, Decimal(60)), (b, Decimal(41))]) == nil)
        #expect(SplitMath.percentage(total: 100, friendPercentages: [(a, Decimal(-1))]) == nil)
        #expect(SplitMath.percentage(total: 100, friendPercentages: [(a, Decimal(101))]) == nil)
        #expect(SplitMath.percentage(total: 100, friendPercentages: [(a, Decimal(25)), (a, Decimal(25))]) == nil)
        #expect(SplitMath.percentage(total: 100, friendPercentages: [(a, Decimal(string: "33.333")!)]) == nil)
        #expect(SplitMath.percentage(total: 100, friendPercentages: [(a, .nan)]) == nil)
        #expect(SplitMath.percentage(total: 0, friendPercentages: [(a, Decimal(25))]) == nil)
        #expect(SplitMath.percentage(total: Decimal(string: "1.001")!, friendPercentages: [(a, Decimal(25))]) == nil)
    }

    @Test func percentageInputRejectsPartialParsingAndAcceptsDecimalComma() {
        #expect(SplitMath.percentageInput(" 25,50 ") == Decimal(string: "25.5"))
        #expect(SplitMath.percentageInput("33.33") == Decimal(string: "33.33"))
        #expect(SplitMath.percentageInput("100") == 100)
        #expect(SplitMath.percentageInput("0") == 0)
        for text in ["", " ", "25abc", "25%", "1e2", "-1", "101", "NaN", "33.333", "2,5.5"] {
            #expect(SplitMath.percentageInput(text) == nil)
        }
    }

    @Test func percentageCalculationHandlesLargestSupportedAmount() throws {
        let total = Decimal(Int64.max) / 100
        let shares = try #require(SplitMath.percentage(total: total,
            friendPercentages: [(UUID(), Decimal(50)), (UUID(), Decimal(50))]))
        #expect(shares.reduce(Decimal.zero) { $0 + $1.amount } == total)
        #expect(shares.allSatisfy { $0.amount >= 0 && SplitMath.cents($0.amount) != nil })
    }

    @Test func percentageAmountsPersistAndPreserveSettlementsAcrossRemoteApply() throws {
        let source = CoreDataLedgerRepository(inMemory: true)
        let destination = CoreDataLedgerRepository(inMemory: true)
        let friend = LedgerFriend(id: UUID(), name: "Nimal")
        try source.saveFriend(friend)
        let expense = LedgerEntry(id: UUID(), kind: .expense, amount: Decimal(string: "1000.01")!,
                                  title: "Lunch", category: "Dining", date: .now, note: "")
        try source.upsert(expense)
        var shares = try #require(SplitMath.percentage(total: expense.amount,
            friendPercentages: [(friend.id, Decimal(string: "33.33")!)]))
        shares[1].settledAt = .now
        let bill = SplitBill(id: UUID(), entryID: expense.id, totalAmount: expense.amount,
                             note: "Shared lunch", shares: shares)
        try source.saveSplitBill(bill)
        let saved = try #require(try source.fetchSplitBills().first)
        try destination.applyRemote(saved)
        let remote = try #require(try destination.fetchSplitBills().first)
        #expect(remote.ownShare == Decimal(string: "666.71"))
        #expect(remote.shares.first { $0.friendID == friend.id } == shares[1])
        #expect(remote.outstanding == 0)
        #expect(remote.isValid)
        #expect(try source.fetchEntries().first?.amount == expense.amount)
    }

    @Test func equalSplitGivesRoundingRemainderToUser() throws {
        let friends = [UUID(), UUID()]
        let shares = try #require(SplitMath.equal(total: 1_000, friendIDs: friends))
        #expect(shares.first?.amount == Decimal(string: "333.34"))
        #expect(shares.dropFirst().map(\.amount) == [Decimal(string: "333.33"), Decimal(string: "333.33")])
        #expect(shares.reduce(Decimal.zero) { $0 + $1.amount } == 1_000)
        let bill = SplitBill(id: UUID(), entryID: UUID(), totalAmount: 1_000,
                             note: "Dinner", shares: shares)
        #expect(bill.isValid)
        #expect(bill.outstanding == Decimal(string: "666.66"))
    }

    @Test func customSharesLeaveTheRestWithUserAndRejectInvalidAmounts() throws {
        let first = UUID(), second = UUID()
        let shares = try #require(SplitMath.custom(total: Decimal(string: "1000.01")!,
                                                    friendAmounts: [(first, Decimal(250)),
                                                                    (second, Decimal(string: "125.33")!)]))
        #expect(shares.first?.amount == Decimal(string: "624.68"))
        #expect(SplitMath.custom(total: 100, friendAmounts: [(first, Decimal(101))]) == nil)
        #expect(SplitMath.custom(total: 100, friendAmounts: [(first, Decimal(string: "1.001")!)]) == nil)
        #expect(SplitMath.equal(total: 100, friendIDs: [first, first]) == nil)
    }

    @Test func splitPersistsAndRemoteUpdatesPreserveSettlement() throws {
        let source = CoreDataLedgerRepository(inMemory: true)
        let destination = CoreDataLedgerRepository(inMemory: true)
        let friend = LedgerFriend(id: UUID(), name: "Kasun")
        try source.saveFriend(friend)
        try destination.applyRemote(friend)
        let category = try #require(source.fetchCategories().first { $0.kind == .expense })
        let expense = LedgerEntry(id: UUID(), kind: .expense, amount: 1_000,
                                  title: "Dinner", category: category.name,
                                  date: .now, note: "", categoryID: category.id)
        try source.upsert(expense)
        let shares = try #require(SplitMath.equal(total: expense.amount, friendIDs: [friend.id]))
        let yesterday = Date.now.addingTimeInterval(-86_400)
        var bill = SplitBill(id: UUID(), entryID: expense.id,
                             totalAmount: expense.amount, note: "", shares: shares,
                             createdAt: yesterday, updatedAt: yesterday)
        try source.saveSplitBill(bill)
        bill.shares[1].settledAt = .now
        bill.updatedAt = bill.updatedAt.addingTimeInterval(1)
        try source.saveSplitBill(bill)
        try destination.applyRemote(bill)
        let saved = try #require(source.fetchSplitBills().first)
        #expect(saved.outstanding == 0)
        #expect(try destination.fetchSplitBills().first?.outstanding == 0)
        #expect(try source.fetchEntries().first?.amount == 1_000)
        let tombstone = try #require(try source.deleteSplitBill(id: bill.id))
        try destination.applyRemote(tombstone)
        #expect(try source.fetchSplitBills().isEmpty)
        #expect(try destination.fetchSplitBills().isEmpty)
        #expect(try source.allSplitBillsForSync().first?.deletedAt != nil)
    }

    @Test func splitMustMatchAnExpenseAndKnownFriend() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let friend = LedgerFriend(id: UUID(), name: "Kasun")
        try repository.saveFriend(friend)
        #expect(throws: LedgerDataError.self) {
            try repository.saveFriend(LedgerFriend(id: UUID(), name: "kasun"))
        }
        let shares = try #require(SplitMath.equal(total: 100, friendIDs: [friend.id]))
        let bill = SplitBill(id: UUID(), entryID: UUID(), totalAmount: 100,
                             note: "", shares: shares)
        #expect(throws: LedgerDataError.self) { try repository.saveSplitBill(bill) }
        let unknown = SplitBill(id: UUID(), entryID: UUID(), totalAmount: 100,
                                note: "", shares: SplitMath.equal(total: 100, friendIDs: [UUID()])!)
        #expect(throws: LedgerDataError.self) { try repository.saveSplitBill(unknown) }
        let category = try #require(repository.fetchCategories().first { $0.kind == .expense })
        let expense = LedgerEntry(id: bill.entryID, kind: .expense, amount: 100,
                                  title: "Taxi", category: category.name, date: .now,
                                  note: "", categoryID: category.id)
        try repository.upsert(expense)
        try repository.saveSplitBill(bill)
        let duplicate = SplitBill(id: UUID(), entryID: expense.id, totalAmount: 100,
                                  note: "", shares: shares)
        #expect(throws: LedgerDataError.self) { try repository.saveSplitBill(duplicate) }
    }
}
