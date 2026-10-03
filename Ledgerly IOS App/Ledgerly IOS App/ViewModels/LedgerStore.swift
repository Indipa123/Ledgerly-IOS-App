import Foundation
import Combine

@MainActor
final class LedgerStore: ObservableObject {
    @Published private(set) var entries: [LedgerEntry] = []
    @Published private(set) var budget: Decimal = 0
    @Published private(set) var categories: [LedgerCategory] = []
    @Published private(set) var paymentMethods: [LedgerPaymentMethod] = []
    @Published var error: String?
    @Published private(set) var syncStatus = "On this device"

    private var repository: any LedgerRepository
    private var cloud: CloudLedgerSync?
    private var accountID: String?

    init(inMemory: Bool = false) {
        repository = CoreDataLedgerRepository(inMemory: inMemory)
        reload()
    }

    init(repository: any LedgerRepository) {
        self.repository = repository
        reload()
    }

    func setAccount(_ uid: String?) {
        guard uid != accountID else { return }
        cloud?.stop()
        cloud = nil
        accountID = uid
        guard let uid else {
            repository = CoreDataLedgerRepository()
            syncStatus = "On this device"
            reload()
            return
        }

        let accountRepository = CoreDataLedgerRepository(accountID: uid)
        repository = accountRepository
        reload()
        let service = CloudLedgerSync()
        cloud = service
        service.onEntry = { [weak self] entry in
            guard let self, self.accountID == uid else { return }
            do { try accountRepository.applyRemote(entry); self.reload() }
            catch { self.error = error.localizedDescription }
        }
        service.onBudget = { [weak self] budget in
            guard let self, self.accountID == uid else { return }
            do { try accountRepository.applyRemote(budget); self.reload() }
            catch { self.error = error.localizedDescription }
        }
        service.onError = { [weak self] message in
            self?.syncStatus = "Cloud sync needs attention"
            self?.error = message
        }
        service.start(userID: uid)
        syncStatus = "Firestore + on device"
        migrateGuestDataIfNeeded(to: accountRepository, cloud: service, uid: uid)
    }

    private func migrateGuestDataIfNeeded(to accountRepository: CoreDataLedgerRepository,
                                          cloud service: CloudLedgerSync, uid: String) {
        let defaults = UserDefaults.standard
        let key = "ledgerly.guestMigrated.\(uid)"
        let claimedBy = defaults.string(forKey: "ledgerly.guestClaimedBy")
        guard !defaults.bool(forKey: key), claimedBy == nil || claimedBy == uid else { return }
        do {
            let guest = CoreDataLedgerRepository()
            let entries = try guest.allEntriesForSync()
            let budget = try guest.currentBudgetForSync()
            for entry in entries {
                try accountRepository.applyRemote(entry)
            }
            if let budget { try accountRepository.applyRemote(budget) }
            reload()
            Task { @MainActor in
                do {
                    for entry in entries { try await service.uploadInitial(entry) }
                    if let budget { try await service.uploadInitialBudget(budget) }
                    guard accountID == uid else { return }
                    defaults.set(uid, forKey: "ledgerly.guestClaimedBy")
                    defaults.set(true, forKey: key)
                    syncStatus = "Firestore + on device"
                } catch {
                    syncStatus = "Cloud sync needs attention"
                    self.error = error.localizedDescription
                }
            }
        } catch {
            syncStatus = "Cloud sync needs attention"
            self.error = error.localizedDescription
        }
    }

    var thisMonth: [LedgerEntry] {
        entries.filter { Calendar.current.isDate($0.date, equalTo: .now, toGranularity: .month) }
    }

    var monthlyIncome: Decimal {
        monthlyTotals.income
    }

    var monthlyExpense: Decimal {
        monthlyTotals.expense
    }

    var spentSoFar: Decimal {
        monthlyTotals.spentSoFar
    }

    var monthlyTotals: LedgerTotals {
        let interval = Calendar.current.dateInterval(of: .month, for: .now)
            ?? DateInterval(start: .distantPast, end: .distantFuture)
        return LedgerCalculations.totals(entries, in: interval, asOf: .now)
    }

    func activeCategories(for kind: EntryKind) -> [LedgerCategory] {
        categories.filter { $0.kind == kind && !$0.isArchived }
    }

    var activePaymentMethods: [LedgerPaymentMethod] {
        paymentMethods.filter { !$0.isArchived }
    }

    @discardableResult
    func save(_ entry: LedgerEntry) -> Bool {
        guard entry.amount > 0,
              categories.contains(where: { $0.id == entry.categoryID && $0.kind == entry.kind && !$0.isArchived }) else {
            error = "Enter a positive amount and choose a matching category."
            return false
        }
        do {
            try repository.upsert(entry)
            if let record = try (repository as? CoreDataLedgerRepository)?.syncEntry(id: entry.id) {
                cloud?.upload(record)
            }
            reload()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func delete(_ entry: LedgerEntry) {
        do {
            try repository.softDelete(id: entry.id)
            if let record = try (repository as? CoreDataLedgerRepository)?.syncEntry(id: entry.id) {
                cloud?.upload(record)
            }
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setBudget(_ amount: Decimal) {
        guard amount >= 0 else { return }
        do {
            try repository.setCurrentBudget(amount)
            if let record = try (repository as? CoreDataLedgerRepository)?.currentBudgetForSync() {
                cloud?.upload(record)
            }
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func saveCategory(name: String, kind: EntryKind) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { error = "Enter a category name."; return false }
        let next = (categories.filter { $0.kind == kind }.map(\.sortIndex).max() ?? -1) + 1
        do {
            try repository.saveCategory(LedgerCategory(id: UUID(), name: clean, kind: kind,
                                                       isSystem: false, isArchived: false, sortIndex: next))
            reload()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func renameCategory(_ category: LedgerCategory, to name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { error = "Enter a category name."; return false }
        do {
            var edited = category
            edited.name = clean
            try repository.saveCategory(edited)
            reload()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func archiveCategory(_ category: LedgerCategory) {
        do {
            try repository.archiveCategory(id: category.id)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func restoreCategory(_ category: LedgerCategory) {
        do {
            var restored = category
            restored.isArchived = false
            try repository.saveCategory(restored)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func savePaymentMethod(name: String, kind: PaymentKind, lastFour: String?) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { error = "Enter a payment method name."; return false }
        let next = (paymentMethods.map(\.sortIndex).max() ?? -1) + 1
        do {
            try repository.savePaymentMethod(LedgerPaymentMethod(
                id: UUID(), name: clean, kind: kind,
                lastFour: lastFour?.trimmingCharacters(in: .whitespacesAndNewlines),
                isArchived: false, sortIndex: next
            ))
            reload()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func updatePaymentMethod(_ method: LedgerPaymentMethod, name: String, kind: PaymentKind, lastFour: String?) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { error = "Enter a payment method name."; return false }
        do {
            var edited = method
            edited.name = clean
            edited.kind = kind
            edited.lastFour = lastFour?.trimmingCharacters(in: .whitespacesAndNewlines)
            try repository.savePaymentMethod(edited)
            reload()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func archivePaymentMethod(_ method: LedgerPaymentMethod) {
        do {
            try repository.archivePaymentMethod(id: method.id)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func restorePaymentMethod(_ method: LedgerPaymentMethod) {
        do {
            var restored = method
            restored.isArchived = false
            try repository.savePaymentMethod(restored)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    private func reload() {
        do {
            entries = try repository.fetchEntries()
            budget = try repository.fetchCurrentBudget()
            categories = try repository.fetchCategories()
            paymentMethods = try repository.fetchPaymentMethods()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
