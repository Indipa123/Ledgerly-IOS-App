import Foundation
import Testing
@testable import LedgerlyDomain

struct BudgetAlertPreferencesTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "ledgerly-alert-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func newInstallStartsWithBothTypesDisabled() throws {
        try withDefaults { defaults in
            let preferences = BudgetAlertPreferences(defaults: defaults)
            #expect(!preferences.isEnabled(.monthly))
            #expect(!preferences.isEnabled(.category))
        }
    }

    @Test func upgradePreservesThePreviousCombinedChoice() throws {
        for enabled in [true, false] {
            try withDefaults { defaults in
                defaults.set(enabled, forKey: "ledgerly.notifications.budgetEnabled")
                let migrated = BudgetAlertPreferences(defaults: defaults)
                #expect(migrated.monthlyEnabled == enabled)
                #expect(migrated.categoryEnabled == enabled)
                migrated.save(to: defaults)
                #expect(BudgetAlertPreferences(defaults: defaults) == migrated)
            }
        }
    }

    @Test func choicesStayIndependentAfterReopening() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: "ledgerly.notifications.budgetEnabled")
            var preferences = BudgetAlertPreferences(defaults: defaults)
            preferences.save(to: defaults)
            preferences.set(false, for: .monthly)
            preferences.save(to: defaults)
            preferences = BudgetAlertPreferences(defaults: defaults)
            #expect(!preferences.monthlyEnabled)
            #expect(preferences.categoryEnabled)
            preferences.set(true, for: .monthly)
            preferences.set(false, for: .category)
            preferences.save(to: defaults)
            let reloaded = BudgetAlertPreferences(defaults: defaults)
            #expect(reloaded.monthlyEnabled)
            #expect(!reloaded.categoryEnabled)
        }
    }

    @Test func cancellingOneTypeLeavesOtherNotificationsAlone() {
        let ids = ["ledgerly.budgetAlert.guest.2026-10.warning",
                   "ledgerly.categoryBudgetAlert.guest.groceries.over",
                   "reminder.guest.123", "place.arrival.123"]
        #expect(ids.filter { $0.hasPrefix(BudgetAlertType.monthly.requestPrefix) } == [ids[0]])
        #expect(ids.filter { $0.hasPrefix(BudgetAlertType.category.requestPrefix) } == [ids[1]])
    }
}
