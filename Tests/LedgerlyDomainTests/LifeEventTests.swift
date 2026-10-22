import Foundation
import Testing
@testable import LedgerlyDomain

@MainActor
struct LifeEventTests {
    @Test func eventTotalsLinkOneExpenseWithoutDuplicatingMonthlySpending() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let event = LifeEvent(id: UUID(), name: "Graduation", kind: .graduation,
                              budget: 1_000, startDate: now, endDate: now.addingTimeInterval(86_400))
        try repository.saveLifeEvent(event)
        let category = try #require(repository.fetchCategories().first { $0.kind == .expense })
        let expense = LedgerEntry(id: UUID(), kind: .expense, amount: 750,
                                  title: "Lunch", category: category.name, date: now,
                                  note: "", categoryID: category.id, eventID: event.id)
        try repository.upsert(expense)
        try repository.upsert(LedgerEntry(id: UUID(), kind: .expense, amount: 125,
                                          title: "Other", category: category.name, date: now,
                                          note: "", categoryID: category.id))
        let saved = try repository.fetchEntries()
        #expect(saved.first(where: { $0.id == expense.id })?.eventID == event.id)
        #expect(event.spent(in: saved) == 750)
        #expect(LedgerCalculations.totals(saved,
            in: DateInterval(start: now.addingTimeInterval(-1),
                             end: now.addingTimeInterval(86_400)),
            asOf: now).expense == 875)
        var eventQuery = TransactionQuery()
        eventQuery.eventID = event.id
        #expect(eventQuery.apply(to: saved, asOf: now).map(\.id) == [expense.id])
        #expect(event.projectedSpent(in: saved, adding: 300, replacing: nil) == 1_050)
        #expect(event.projectedSpent(in: saved, adding: 300, replacing: expense.id) == 300)
    }

    @Test func eventAndOverrideReasonSurviveCloudSnapshotAndRemoteApply() throws {
        let source = CoreDataLedgerRepository(inMemory: true)
        let destination = CoreDataLedgerRepository(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let event = LifeEvent(id: UUID(), name: "Avurudu", kind: .avurudu,
                              budget: 400, startDate: now, endDate: now.addingTimeInterval(86_400))
        try source.saveLifeEvent(event)
        try destination.applyRemote(event)
        #expect(try destination.fetchLifeEvents().first == event)

        let category = try #require(source.fetchCategories().first { $0.kind == .expense })
        let expense = LedgerEntry(id: UUID(), kind: .expense, amount: 500,
                                  title: "Food", category: category.name, date: now,
                                  note: "", categoryID: category.id, eventID: event.id,
                                  budgetOverrideReason: "More guests arrived")
        try source.upsert(expense)
        let cloud = try #require(try source.syncEntry(id: expense.id))
        #expect(cloud.eventID == event.id)
        #expect(cloud.budgetOverrideReason == "More guests arrived")
        try destination.applyRemote(cloud)
        let copied = try #require(destination.fetchEntries().first)
        #expect(copied.eventID == event.id)
        #expect(copied.budgetOverrideReason == "More guests arrived")
        #expect(event.spent(in: [copied]) == 500)
    }

    @Test func invalidEventsAndIncomeTagsAreRejected() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let now = Date()
        let invalid = LifeEvent(id: UUID(), name: " ", kind: .other,
                                budget: 0, startDate: now, endDate: now)
        #expect(throws: LedgerDataError.self) { try repository.saveLifeEvent(invalid) }
        let event = LifeEvent(id: UUID(), name: "Trip", kind: .trip,
                              budget: 100, startDate: now, endDate: now)
        try repository.saveLifeEvent(event)
        let category = try #require(repository.fetchCategories().first { $0.kind == .income })
        let income = LedgerEntry(id: UUID(), kind: .income, amount: 100,
                                 title: "Refund", category: category.name, date: now,
                                 note: "", categoryID: category.id, eventID: event.id)
        #expect(throws: LedgerDataError.self) { try repository.upsert(income) }
    }

    @Test func completedEventKeepsFinalSnapshotAndRejectsNewAssignments() throws {
        let repository = CoreDataLedgerRepository(inMemory: true)
        let now = Date()
        var event = LifeEvent(id: UUID(), name: "Trip", kind: .trip,
                              budget: 100, startDate: now, endDate: now)
        try repository.saveLifeEvent(event)
        event.completedAt = now
        event.completionSpent = 80
        event.updatedAt = now.addingTimeInterval(1)
        try repository.saveLifeEvent(event)
        let saved = try #require(repository.fetchLifeEvents().first)
        #expect(saved.completionSpent == 80)
        let category = try #require(repository.fetchCategories().first { $0.kind == .expense })
        let expense = LedgerEntry(id: UUID(), kind: .expense, amount: 20,
                                  title: "Snack", category: category.name, date: now,
                                  note: "", categoryID: category.id, eventID: event.id)
        #expect(throws: LedgerDataError.self) { try repository.upsert(expense) }
    }
}
