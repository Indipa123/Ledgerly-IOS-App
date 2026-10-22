import Foundation
import WidgetKit

@MainActor
enum BudgetWidgetPublisher {
    static func publish(budget: Decimal, entries: [LedgerEntry]) throws {
        let snapshot = BudgetWidgetSnapshot(budget: budget,
            expenses: entries.filter { $0.kind == .expense }.map {
                .init(date: $0.date, amount: $0.amount)
            }, amountsHidden: UserDefaults.standard.bool(forKey: "ledgerly.appLock.enabled"))
        if try BudgetWidgetStorage.write(snapshot) {
            WidgetCenter.shared.reloadTimelines(ofKind: BudgetWidgetStorage.kind)
        }
    }

    static func clear() throws {
        try BudgetWidgetStorage.clear()
        WidgetCenter.shared.reloadTimelines(ofKind: BudgetWidgetStorage.kind)
    }
}
