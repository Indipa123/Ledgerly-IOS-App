import Foundation
import Combine

@MainActor
final class LedgerStore: ObservableObject {
    @Published private(set) var entries: [LedgerEntry] = []
    @Published private(set) var budget: Decimal = 0
    @Published private(set) var categoryBudgets: [CategoryBudget] = []
    @Published private(set) var lifeEvents: [LifeEvent] = []
    @Published private(set) var friends: [LedgerFriend] = []
    @Published private(set) var splitBills: [SplitBill] = []
    @Published private(set) var categories: [LedgerCategory] = []
    @Published private(set) var paymentMethods: [LedgerPaymentMethod] = []
    @Published private(set) var reminders: [LedgerReminder] = []
    @Published private(set) var places: [LedgerPlace] = []
    @Published private(set) var categoryMemory = CategoryMemoryIndex(entries: [])
    @Published private(set) var categoryLearningScope = UUID()
    @Published private(set) var undoableDeletion: LedgerEntry?
    @Published var error: String?
    @Published private(set) var syncStatus = "On this device"
    @Published private(set) var pendingCloudChanges = 0
    @Published private(set) var cloudUsingCache = false
    @Published private(set) var cloudSyncError: String?
    @Published private(set) var uploadingExistingData = false
    @Published private(set) var budgetWidgetError: String?
    private var hasCloudSnapshot = false
    private var publishesBudgetWidget = false

    private var repository: any LedgerRepository
    private var cloud: CloudLedgerSync?
    private var library: CloudLibraryController?
    private var basePendingCloudChanges = 0
    private var accountID: String?
    private var guestUploadFailed = false
    private var writeUploadFailed = false
    private var excludedCategoryEntryIDs: Set<UUID> = []
    private var deletionTask: Task<Void, Never>?
    private lazy var seedCategoryModel = SeedCategoryModel()
    let personalLearning = PersonalCategoryLearningController()
    private var learningObserver: AnyCancellable?
    private let persistsPersonalLearning: Bool
    let notifications = LedgerNotificationService()

    init(inMemory: Bool = false) {
        persistsPersonalLearning = !inMemory
        repository = CoreDataLedgerRepository(inMemory: inMemory)
        learningObserver = personalLearning.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if !inMemory {
            ReceiptImageStore.setAccount(nil)
            if let repo = repository as? CoreDataLedgerRepository { try? ReceiptImageStore.migrateLegacy(Set((try? repo.allEntriesForSync())?.map(\.id) ?? [])) }
            ReceiptImageStore.clearInterruptedDeletions()
        }
        if !inMemory { excludedCategoryEntryIDs = Self.loadLearningExclusions(accountID: nil) }
        reload()
        Task { await notifications.scheduleExisting(reminders, owner: nil) }
    }

    init(repository: any LedgerRepository) {
        persistsPersonalLearning = false
        self.repository = repository
        learningObserver = personalLearning.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        reload()
    }

    func setAccount(_ uid: String?) {
        notifications.setAccount(uid)
        guard uid != accountID else { return }
        if publishesBudgetWidget {
            do { try BudgetWidgetPublisher.clear(); budgetWidgetError = nil }
            catch { budgetWidgetError = "Could not refresh the Home Screen widget. Open Ledgerly again to retry." }
        }
        finishPendingDeletion()
        notifications.cancelAll(reminders, owner: accountID)
        library?.stop(); library = nil
        cloud?.stop()
        cloud = nil
        pendingCloudChanges = 0
        basePendingCloudChanges = 0
        cloudUsingCache = false
        cloudSyncError = nil
        uploadingExistingData = false
        hasCloudSnapshot = false
        guestUploadFailed = false
        writeUploadFailed = false
        categoryLearningScope = UUID()
        accountID = uid
        ReceiptImageStore.setAccount(uid)
        ReceiptImageStore.clearInterruptedDeletions()
        excludedCategoryEntryIDs = Self.loadLearningExclusions(accountID: uid)
        guard let uid else {
            repository = CoreDataLedgerRepository()
            syncStatus = "On this device"
            reload()
            Task { await notifications.scheduleExisting(reminders, owner: nil) }
            return
        }

        let accountRepository = CoreDataLedgerRepository(accountID: uid)
        repository = accountRepository
        do { try ReceiptImageStore.migrateLegacy(Set(try accountRepository.allEntriesForSync().map(\.id))) } catch { self.error = error.localizedDescription }
        reload()
        Task { await notifications.scheduleExisting(reminders, owner: uid) }
        if AccountDeletionJournal.shared.contains(uid) {
            syncStatus = "Account deletion pending"
            return
        }
        let service = CloudLedgerSync()
        cloud = service
        service.onDeletionRequested = { [weak self] in
            guard let self, self.accountID == uid, !AccountDeletionJournal.shared.contains(uid) else { return }
            do {
                if !AccountDeletionJournal.shared.contains(uid) {
                    try AccountDeletionJournal.shared.save(.init(accountID: uid, requestedAt: .now,
                        includesClaimedGuest: UserDefaults.standard.string(forKey: "ledgerly.guestClaimedBy") == uid))
                }
                self.suspendForAccountDeletion(uid)
            } catch { self.error = error.localizedDescription }
        }
        service.onEntry = { [weak self] entry in
            guard let self, self.accountID == uid, !AccountDeletionJournal.shared.contains(uid) else { return }
            do { try accountRepository.applyRemote(entry); self.reload(captureLibrary: false) }
            catch { self.error = error.localizedDescription }
        }
        service.onBudget = { [weak self] budget in
            guard let self, self.accountID == uid, !AccountDeletionJournal.shared.contains(uid) else { return }
            do { try accountRepository.applyRemote(budget); self.reload(captureLibrary: false) }
            catch { self.error = error.localizedDescription }
        }
        service.onCategoryBudget = { [weak self] budget in
            guard let self, self.accountID == uid, !AccountDeletionJournal.shared.contains(uid) else { return }
            do { try accountRepository.applyRemote(budget); self.reload(captureLibrary: false) }
            catch { self.error = error.localizedDescription }
        }
        service.onLifeEvent = { [weak self] event in
            guard let self, self.accountID == uid, !AccountDeletionJournal.shared.contains(uid) else { return }
            do { try accountRepository.applyRemote(event); self.reload(captureLibrary: false) }
            catch { self.error = error.localizedDescription }
        }
        service.onFriend = { [weak self] friend in
            guard let self, self.accountID == uid, !AccountDeletionJournal.shared.contains(uid) else { return }
            do { try accountRepository.applyRemote(friend); self.reload(captureLibrary: false) }
            catch { self.error = error.localizedDescription }
        }
        service.onSplitBill = { [weak self] bill in
            guard let self, self.accountID == uid, !AccountDeletionJournal.shared.contains(uid) else { return }
            do { try accountRepository.applyRemote(bill); self.reload(captureLibrary: false) }
            catch { self.error = error.localizedDescription }
        }
        service.onError = { [weak self] message in
            guard let self, self.accountID == uid, !AccountDeletionJournal.shared.contains(uid) else { return }
            self.cloudSyncError = message
            self.syncStatus = "Sync needs attention"
        }
        service.onWriteError = { [weak self] message in
            guard let self, self.accountID == uid, !AccountDeletionJournal.shared.contains(uid) else { return }
            self.writeUploadFailed = true
            self.cloudSyncError = message
            self.refreshSyncStatus()
        }
        service.onStatus = { [weak self] pending, fromCache in
            guard let self, self.accountID == uid, !AccountDeletionJournal.shared.contains(uid) else { return }
            self.hasCloudSnapshot = true
            self.basePendingCloudChanges = pending
            self.pendingCloudChanges = pending + (self.library?.pendingCount ?? 0)
            self.cloudUsingCache = fromCache
            if !fromCache && !self.guestUploadFailed && !self.writeUploadFailed {
                self.cloudSyncError = nil
            }
            self.refreshSyncStatus()
        }
        do {
            let library = try CloudLibraryController(uid: uid, repository: accountRepository, service: service)
            self.library = library
            library.onError = { [weak self] message in
                guard let self, self.accountID == uid else { return }
                self.writeUploadFailed = true; self.cloudSyncError = message; self.refreshSyncStatus()
            }
            library.onPending = { [weak self] count in
                guard let self, self.accountID == uid else { return }
                self.pendingCloudChanges = self.basePendingCloudChanges + count
                self.refreshSyncStatus()
            }
            library.onChange = { [weak self] kinds, changedReminders in
                guard let self, self.accountID == uid else { return }
                let previous = self.reminders
                self.reload(captureLibrary: false)
                if kinds.contains(.reminder) {
                    let ids = Set(self.reminders.map(\.id))
                    for reminder in previous where changedReminders.contains(reminder.id) && !ids.contains(reminder.id) { self.notifications.cancel(reminder, owner: uid) }
                    let reminders = self.reminders.filter { changedReminders.contains($0.id) }
                    Task { await self.notifications.scheduleExisting(reminders, owner: uid) }
                }
            }
            service.onLibraryRecords = { [weak library] records in library?.receive(records) }
        } catch { writeUploadFailed = true; cloudSyncError = error.localizedDescription }
        service.start(userID: uid)
        syncStatus = "Checking sync"
        migrateGuestLibraryIfNeeded(to: accountRepository, uid: uid)
        migrateGuestDataIfNeeded(to: accountRepository, cloud: service, uid: uid)
        library?.capture()
    }

    private func migrateGuestLibraryIfNeeded(to accountRepository: CoreDataLedgerRepository, uid: String) {
        let defaults = UserDefaults.standard
        let key = "ledgerly.libraryGuestImported.\(uid)"
        let claimed = defaults.string(forKey: "ledgerly.guestClaimedBy")
        guard !defaults.bool(forKey: key), claimed == nil || claimed == uid,
              !AccountDeletionJournal.shared.contains(uid) else { return }
        defaults.set(uid, forKey: "ledgerly.guestClaimedBy")
        do {
            let guest = CoreDataLedgerRepository()
            let categories = Set(try accountRepository.fetchCategories().map(\.id))
            for value in try guest.fetchCategories() where !categories.contains(value.id) { try accountRepository.applyLibraryCategory(value) }
            let methods = Set(try accountRepository.fetchPaymentMethods().map(\.id))
            for value in try guest.fetchPaymentMethods() where !methods.contains(value.id) { try accountRepository.applyLibraryPayment(value) }
            let reminders = Set(try accountRepository.fetchReminders().map(\.id))
            for value in try guest.fetchReminders() where !reminders.contains(value.id) { try accountRepository.saveReminder(value, acceptingPast: true) }
            let places = Set(try accountRepository.fetchPlaces().map(\.id))
            for value in try guest.fetchPlaces() where !places.contains(value.id) { try accountRepository.savePlace(value) }
            try ReceiptImageStore.migrateLegacy(Set(try accountRepository.allEntriesForSync().map(\.id)), includeGuest: true)
            defaults.set(true, forKey: key)
            reload()
            let restoredReminders = self.reminders
            Task { await notifications.scheduleExisting(restoredReminders, owner: uid) }
        } catch { self.error = "Could not migrate local library: \(error.localizedDescription)" }
    }

    private func migrateGuestDataIfNeeded(to accountRepository: CoreDataLedgerRepository,
                                          cloud service: CloudLedgerSync, uid: String) {
        let defaults = UserDefaults.standard
        let key = "ledgerly.guestMigrated.\(uid)"
        let claimedBy = defaults.string(forKey: "ledgerly.guestClaimedBy")
        guard !defaults.bool(forKey: key), claimedBy == nil || claimedBy == uid else { return }
        guard !AccountDeletionJournal.shared.contains(uid) else { return }
        // Claim before asynchronous uploads so interruption cannot import this guest ledger into a different account.
        defaults.set(uid, forKey: "ledgerly.guestClaimedBy")
        do {
            let guest = CoreDataLedgerRepository()
            let entries = try guest.allEntriesForSync()
            try ReceiptImageStore.migrateLegacy(Set(entries.map(\.id)), includeGuest: true)
            let budget = try guest.currentBudgetForSync()
            let categoryBudgets = try guest.allCategoryBudgetsForSync()
            let lifeEvents = try guest.fetchLifeEvents()
            let friends = try guest.fetchFriends()
            let splitBills = try guest.allSplitBillsForSync()
            for category in try guest.fetchCategories() { try accountRepository.applyLibraryCategory(category) }
            for method in try guest.fetchPaymentMethods() { try accountRepository.applyLibraryPayment(method) }
            for reminder in try guest.fetchReminders() { try accountRepository.saveReminder(reminder, acceptingPast: true) }
            let places = try guest.fetchPlaces()
            for place in places { try accountRepository.savePlace(place) }
            for entry in entries {
                try accountRepository.applyRemote(entry)
            }
            if let budget { try accountRepository.applyRemote(budget) }
            for categoryBudget in categoryBudgets {
                try accountRepository.applyRemote(categoryBudget)
            }
            for event in lifeEvents { try accountRepository.applyRemote(event) }
            for friend in friends { try accountRepository.applyRemote(friend) }
            for bill in splitBills { try accountRepository.applyRemote(bill) }
            reload()
            uploadingExistingData = !entries.isEmpty || budget != nil ||
                !categoryBudgets.isEmpty || !lifeEvents.isEmpty || !friends.isEmpty || !splitBills.isEmpty
            guestUploadFailed = false
            refreshSyncStatus()
            Task { @MainActor in
                do {
                    for entry in entries { try await service.uploadInitial(entry) }
                    if let budget { try await service.uploadInitialBudget(budget) }
                    for categoryBudget in categoryBudgets {
                        try await service.uploadInitial(categoryBudget)
                    }
                    for event in lifeEvents { try await service.uploadInitial(event) }
                    for friend in friends { try await service.uploadInitial(friend) }
                    for bill in splitBills { try await service.uploadInitial(bill) }
                    guard accountID == uid, !AccountDeletionJournal.shared.contains(uid) else { return }
                    defaults.set(uid, forKey: "ledgerly.guestClaimedBy")
                    defaults.set(true, forKey: key)
                    uploadingExistingData = false
                    guestUploadFailed = false
                    if !writeUploadFailed { cloudSyncError = nil }
                    refreshSyncStatus()
                } catch {
                    guard accountID == uid, !AccountDeletionJournal.shared.contains(uid) else { return }
                    uploadingExistingData = false
                    guestUploadFailed = true
                    syncStatus = "Sync needs attention"
                    cloudSyncError = error.localizedDescription
                }
            }
        } catch {
            guestUploadFailed = true
            syncStatus = "Sync needs attention"
            cloudSyncError = error.localizedDescription
        }
    }

    func retryCloudSync() {
        if let accountID, AccountDeletionJournal.shared.contains(accountID) { return }
        guard let uid = accountID,
              let service = cloud,
              let accountRepository = repository as? CoreDataLedgerRepository else { return }
        cloudSyncError = nil
        guestUploadFailed = false
        writeUploadFailed = false
        hasCloudSnapshot = false
        pendingCloudChanges = 0
        cloudUsingCache = false
        syncStatus = "Checking sync"
        service.start(userID: uid)
        library?.retry()
        migrateGuestDataIfNeeded(to: accountRepository, cloud: service, uid: uid)
        Task { @MainActor in
            do {
                for entry in try accountRepository.allEntriesForSync() {
                    try await service.uploadInitial(entry)
                }
                if let budget = try accountRepository.currentBudgetForSync() {
                    try await service.uploadInitialBudget(budget)
                }
                for categoryBudget in try accountRepository.allCategoryBudgetsForSync() {
                    try await service.uploadInitial(categoryBudget)
                }
                for event in try accountRepository.fetchLifeEvents() {
                    try await service.uploadInitial(event)
                }
                for friend in try accountRepository.fetchFriends() {
                    try await service.uploadInitial(friend)
                }
                for bill in try accountRepository.allSplitBillsForSync() {
                    try await service.uploadInitial(bill)
                }
                guard accountID == uid, !AccountDeletionJournal.shared.contains(uid) else { return }
                refreshSyncStatus()
            } catch {
                guard accountID == uid, !AccountDeletionJournal.shared.contains(uid) else { return }
                writeUploadFailed = true
                cloudSyncError = error.localizedDescription
                refreshSyncStatus()
            }
        }
    }

    var syncBannerMessage: String? {
        guard accountID != nil else { return nil }
        if cloudSyncError != nil {
            return "Sync needs attention. Changes remain saved on this device; retry from Settings."
        }
        if uploadingExistingData {
            return "Uploading existing data from this device to your account."
        }
        if pendingCloudChanges > 0 {
            let count = pendingCloudChanges
            return "\(count) \(count == 1 ? "change is" : "changes are") saved on this device and waiting to sync."
        }
        if cloudUsingCache {
            return "Showing saved data while reconnecting to your account."
        }
        return nil
    }

    func signOutSyncMessage(for uid: String) -> String {
        let syncMessage: String
        if accountID != uid {
            syncMessage = "Cloud sync for this account has not been confirmed."
        } else if pendingCloudChanges > 0 {
            let count = pendingCloudChanges
            syncMessage = "\(count) cloud \(count == 1 ? "record is" : "records are") still waiting to sync." +
                (cloudSyncError != nil ? " Cloud sync also needs attention." : "")
        } else if uploadingExistingData {
            syncMessage = "Existing data is still being uploaded to your account."
        } else if cloudSyncError != nil {
            syncMessage = "Sync needs attention. Some changes may only be saved on this device."
        } else if !hasCloudSnapshot || cloudUsingCache {
            syncMessage = "Cloud sync has not been confirmed. Ledgerly may be using saved data."
        } else {
            syncMessage = "The last confirmed cloud status was up to date."
        }
        let localWarning = hasUnconfirmedSync(for: uid)
            ? " Keep Ledgerly installed until syncing succeeds; deleting the app can remove unsynced data." : ""
        return syncMessage + localWarning
    }

    func hasUnconfirmedSync(for uid: String) -> Bool {
        accountID != uid || !hasCloudSnapshot || pendingCloudChanges > 0 ||
            uploadingExistingData || cloudSyncError != nil || cloudUsingCache
    }

    private func refreshSyncStatus() {
        if cloudSyncError != nil {
            syncStatus = "Sync needs attention"
        } else if uploadingExistingData {
            syncStatus = "Uploading existing data"
        } else if !hasCloudSnapshot {
            syncStatus = "Checking sync"
        } else if pendingCloudChanges > 0 {
            syncStatus = "\(pendingCloudChanges) waiting to sync"
        } else if cloudUsingCache {
            syncStatus = "Using saved data"
        } else {
            syncStatus = "Up to date"
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

    func spendingPattern(for place: LedgerPlace) -> PlaceSpendingPattern {
        PlaceSpendingPattern.analyze(entries: entries, place: place,
            activeCategoryIDs: Set(activeCategories(for: .expense).map(\.id)),
            excludedCategoryEntryIDs: excludedCategoryEntryIDs)
    }

    func suggestedCategory(for kind: EntryKind, title: String,
                           placeID: UUID? = nil) -> CategoryMemorySuggestion? {
        categoryAssistance(for: kind, title: title, placeID: placeID).suggestion
    }

    func categoryAssistance(for kind: EntryKind, title: String,
                            placeID: UUID? = nil) -> CategoryAssistance {
        let active = activeCategories(for: kind)
        if let remembered = categoryMemory.suggestion(for: title, kind: kind,
                                                       activeCategories: active) {
            return .init(suggestion: remembered)
        }
        if kind == .expense, let placeID,
           let place = places.first(where: { $0.id == placeID }) {
            let pattern = spendingPattern(for: place)
            if let categoryID = pattern.categoryID {
                return .init(suggestion: .init(categoryID: categoryID,
                    exampleCount: pattern.categoryExampleCount, match: .place))
            }
        }
        if personalLearning.hasModel(for: kind) {
            return personalLearning.assistance(title: title, kind: kind, categories: active)
        }
        return seedCategoryModel.assistance(for: title, kind: kind, activeCategories: active)
    }

    var learnedCategoryGroups: [CategoryLearningGroup] {
        CategoryMemoryIndex.groups(entries: entries, excludedEntryIDs: excludedCategoryEntryIDs)
    }

    var excludedCategoryExamples: [LedgerEntry] {
        CategoryLearningReview.excludedExamples(entries: entries,
                                                excludedEntryIDs: excludedCategoryEntryIDs)
    }

    func restoreCategoryLearning(for ids: Set<UUID>, scope: UUID) {
        guard scope == categoryLearningScope else { return }
        let updated = CategoryLearningReview.restoringExamples(ids,
            excludedEntryIDs: excludedCategoryEntryIDs, entries: entries)
        guard updated != excludedCategoryEntryIDs else { return }
        excludedCategoryEntryIDs = updated
        saveLearningExclusions()
        refreshCategoryLearning()
    }

    var categoryReviewEntries: [LedgerEntry] {
        CategoryReviewQueue.pending(entries: entries, excludedEntryIDs: excludedCategoryEntryIDs)
    }

    var reviewedCategoryEntries: [LedgerEntry] {
        CategoryReviewQueue.reviewed(entries: entries, excludedEntryIDs: excludedCategoryEntryIDs)
    }

    func markCategoryReviewed(_ entry: LedgerEntry, scope: UUID) {
        updateCategoryReview(entry, reviewed: true, scope: scope)
    }

    func reopenCategoryReview(_ entry: LedgerEntry, scope: UUID) {
        updateCategoryReview(entry, reviewed: false, scope: scope)
    }

    private func updateCategoryReview(_ entry: LedgerEntry, reviewed: Bool, scope: UUID) {
        guard scope == categoryLearningScope else { return }
        do {
            let saved: Bool
            if reviewed { saved = try repository.markCategoryReviewed(entry) }
            else { saved = try repository.reopenCategoryReview(entry) }
            guard saved else {
                error = "This transaction changed. Open it again before updating its review status."
                return
            }
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func evaluateCategoryLearning() -> CategoryEvaluationReport? {
        CategoryEvaluation.evaluate(entries: entries, activeCategories: categories,
                                    excludedEntryIDs: excludedCategoryEntryIDs)
    }

    func forgetCategoryLearning(for group: CategoryLearningGroup) {
        excludedCategoryEntryIDs.formUnion(group.entryIDs)
        saveLearningExclusions()
        refreshCategoryLearning()
    }

    func forgetCategoryLearning(for entryID: UUID) {
        guard entries.contains(where: { $0.id == entryID }) else { return }
        excludedCategoryEntryIDs.insert(entryID)
        saveLearningExclusions()
        refreshCategoryLearning()
    }

    func forgetAllCategoryLearning() {
        excludedCategoryEntryIDs.formUnion(entries.map(\.id))
        saveLearningExclusions()
        personalLearning.clearAll()
        refreshCategoryLearning()
    }

    private static func learningExclusionsKey(accountID: String?) -> String {
        "ledgerly.categoryLearning.excluded.\(accountID ?? "guest")"
    }

    private static func loadLearningExclusions(accountID: String?) -> Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: learningExclusionsKey(accountID: accountID)) ?? [])
            .compactMap(UUID.init(uuidString:)))
    }

    private func saveLearningExclusions() {
        UserDefaults.standard.set(excludedCategoryEntryIDs.map(\.uuidString).sorted(),
                                  forKey: Self.learningExclusionsKey(accountID: accountID))
    }

    private func refreshCategoryLearning() {
        categoryMemory = CategoryMemoryIndex(entries: entries, excludedEntryIDs: excludedCategoryEntryIDs)
        let asOf = Date.now
        let active = Set(categories.filter { !$0.isArchived }.map(\.id))
        let examples = entries.compactMap { entry -> PersonalCategoryExample? in
            guard !excludedCategoryEntryIDs.contains(entry.id), let id = entry.categoryID, active.contains(id),
                  categories.contains(where: { $0.id == id && $0.kind == entry.kind }), entry.date <= asOf,
                  CategorySuggestionPolicy.hasDistinctiveDescription(entry.title) else { return nil }
            let text = CategoryMemoryIndex.normalized(entry.title)
            guard text.count >= 4 else { return nil }
            let example = PersonalCategoryExample(id: entry.id, text: text, label: id.uuidString,
                kind: entry.kind.rawValue, date: entry.date, correctionDate: CategoryCorrectionPolicy.date(for: entry))
            return example.availableAt <= asOf ? example : nil
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let revision = PersonalRetrainingPolicy.revision(categories.map {
            "\($0.id.uuidString)|\($0.kind.rawValue)|\($0.name)|\($0.isArchived)"
        })
        personalLearning.synchronize(accountID: accountID, examples: examples, categoryRevision: revision,
            persistent: persistsPersonalLearning,
            blocked: accountID.map { AccountDeletionJournal.shared.contains($0) } ?? false)
    }

    var activePaymentMethods: [LedgerPaymentMethod] {
        paymentMethods.filter { !$0.isArchived }
    }

    @discardableResult
    func saveLifeEvent(_ event: LifeEvent) -> Bool {
        if lifeEvents.contains(where: { $0.id == event.id && $0.completedAt != nil && event.completedAt == nil }) {
            error = "This event is already completed."
            return false
        }
        var changed = event
        changed.updatedAt = .now
        do {
            try repository.saveLifeEvent(changed)
            cloud?.upload(changed)
            reload()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func completeLifeEvent(_ event: LifeEvent) -> Bool {
        guard event.completedAt == nil else { return true }
        finishPendingDeletion()
        var completed = event
        completed.completedAt = .now
        completed.completionSpent = event.spent(in: entries)
        return saveLifeEvent(completed)
    }

    @discardableResult
    func saveFriend(_ friend: LedgerFriend) -> Bool {
        var changed = friend
        changed.updatedAt = .now
        do {
            try repository.saveFriend(changed)
            cloud?.upload(changed)
            reload()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveSplitBill(_ bill: SplitBill) -> Bool {
        var changed = bill
        changed.updatedAt = .now
        do {
            try repository.saveSplitBill(changed)
            cloud?.upload(changed)
            reload()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func settleShare(billID: UUID, shareID: UUID, settled: Bool) {
        guard var bill = splitBills.first(where: { $0.id == billID }),
              let index = bill.shares.firstIndex(where: { $0.id == shareID && $0.friendID != nil }) else { return }
        bill.shares[index].settledAt = settled ? .now : nil
        _ = saveSplitBill(bill)
    }

    func deleteSplitBill(id: UUID) {
        do {
            if let bill = try repository.deleteSplitBill(id: id) { cloud?.upload(bill) }
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func save(_ entry: LedgerEntry) -> Bool {
        let prior = entries.first { $0.id == entry.id }
        if let existing = entries.first(where: { $0.id == entry.id }),
           lifeEvents.contains(where: { $0.id == existing.eventID && $0.completedAt != nil }) {
            error = "This expense belongs to a completed event."
            return false
        }
        if splitBills.contains(where: { $0.entryID == entry.id &&
            ($0.totalAmount != entry.amount || entry.kind != .expense) }) {
            error = "Remove or update this expense's split before changing its amount."
            return false
        }
        guard entry.amount > 0,
              categories.contains(where: { $0.id == entry.categoryID && $0.kind == entry.kind && !$0.isArchived }) else {
            error = "Enter a positive amount and choose a matching category."
            return false
        }
        do {
            let previousSpent = spentSoFar
            let now = Date.now
            let month = Calendar.current.dateInterval(of: .month, for: now)
            let previousCategorySpending: [String: Decimal] = month.map { interval in
                Dictionary(uniqueKeysWithValues: categoryBudgets.map { limit in
                    (limit.id, limit.spent(in: entries, month: interval, asOf: now))
                })
            } ?? [:]
            try repository.upsert(entry)
            if let record = try (repository as? CoreDataLedgerRepository)?.syncEntry(id: entry.id) {
                cloud?.upload(record)
            }
            reload()
            if let prior, prior.kind == entry.kind, prior.categoryID != entry.categoryID {
                personalLearning.recordCorrection(entryID: entry.id)
            }
            let currentSpent = spentSoFar
            let currentBudget = budget
            let owner = accountID
            Task { await notifications.checkBudgetCrossing(previous: previousSpent, current: currentSpent,
                                                           budget: currentBudget, owner: owner) }
            if let month {
                for limit in categoryBudgets {
                    let current = limit.spent(in: entries, month: month, asOf: now)
                    let previous = previousCategorySpending[limit.id] ?? 0
                    Task { await notifications.checkCategoryBudgetCrossing(
                        previous: previous, current: current, limit: limit, owner: owner) }
                }
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func delete(_ entry: LedgerEntry) {
        guard !splitBills.contains(where: { $0.entryID == entry.id }) else {
            error = "Remove this expense's split before deleting it."
            return
        }
        guard !lifeEvents.contains(where: { $0.id == entry.eventID && $0.completedAt != nil }) else {
            error = "This expense belongs to a completed event."
            return
        }
        do {
            try repository.softDelete(id: entry.id)
            ReceiptImageStore.delete(for: entry.id)
            library?.captureMedia(kind: .receipt, id: entry.id.uuidString, payload: nil)
            if let record = try (repository as? CoreDataLedgerRepository)?.syncEntry(id: entry.id) {
                cloud?.upload(record)
            }
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteUndoably(_ entry: LedgerEntry) {
        guard !splitBills.contains(where: { $0.entryID == entry.id }) else {
            error = "Remove this expense's split before deleting it."
            return
        }
        guard !lifeEvents.contains(where: { $0.id == entry.eventID && $0.completedAt != nil }) else {
            error = "This expense belongs to a completed event."
            return
        }
        finishPendingDeletion()
        do {
            try ReceiptImageStore.stageDeletion(for: entry.id)
            do {
                try repository.softDelete(id: entry.id)
            } catch {
                try? ReceiptImageStore.restoreStaged(for: entry.id)
                throw error
            }
            undoableDeletion = entry
            reload()
            do {
                if let record = try (repository as? CoreDataLedgerRepository)?.syncEntry(id: entry.id) {
                    cloud?.upload(record)
                }
            } catch {
                self.error = error.localizedDescription
            }
            deletionTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.finishPendingDeletion(ifMatching: entry.id)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func undoDeletion() {
        guard let entry = undoableDeletion else { return }
        do {
            try repository.restoreDeleted(id: entry.id)
            try ReceiptImageStore.restoreStaged(for: entry.id)
            finishPendingDeletion(ifMatching: entry.id)
            reload()
            if let record = try (repository as? CoreDataLedgerRepository)?.syncEntry(id: entry.id) {
                cloud?.upload(record)
            }
        } catch {
            deletionTask?.cancel()
            deletionTask = nil
            self.error = error.localizedDescription
        }
    }

    private func finishPendingDeletion(ifMatching id: UUID? = nil) {
        guard let entry = undoableDeletion, id == nil || id == entry.id else { return }
        deletionTask?.cancel()
        deletionTask = nil
        ReceiptImageStore.finishDeletion(for: entry.id)
        if (try? (repository as? CoreDataLedgerRepository)?.syncEntry(id: entry.id)?.deletedAt) != nil {
            library?.captureMedia(kind: .receipt, id: entry.id.uuidString, payload: nil)
        }
        undoableDeletion = nil
    }

    @discardableResult
    func setBudget(_ amount: Decimal) -> Bool {
        guard amount >= 0 else { return false }
        do {
            let previousBudget = budget
            try repository.setCurrentBudget(amount)
            if let record = try (repository as? CoreDataLedgerRepository)?.currentBudgetForSync() {
                cloud?.upload(record)
            }
            reload()
            if amount < previousBudget || previousBudget == 0 {
                let currentSpent = spentSoFar
                let owner = accountID
                Task { await notifications.checkBudgetCrossing(previous: 0, current: currentSpent,
                                                               budget: amount, owner: owner) }
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func setCategoryBudget(for category: LedgerCategory, amount: Decimal) -> Bool {
        guard let currentCategory = categories.first(where: {
            $0.id == category.id && $0.kind == .expense && !$0.isArchived
        }), amount >= 0 else {
            error = LedgerDataError.invalidCategoryBudget.localizedDescription
            return false
        }
        let now = Date.now
        let limit = CategoryBudget(monthKey: CategoryBudget.monthKey(for: now),
                                   categoryName: currentCategory.name, amount: amount, updatedAt: now)
        do {
            let previousAmount = categoryBudgets.first(where: { $0.id == limit.id })?.amount
            try repository.setCategoryBudget(limit)
            cloud?.upload(limit)
            reload()
            if amount > 0, previousAmount.map({ amount < $0 }) ?? true,
               let month = Calendar.current.dateInterval(of: .month, for: now) {
                let current = limit.spent(in: entries, month: month, asOf: now)
                let owner = accountID
                Task { await notifications.checkCategoryBudgetCrossing(
                    previous: 0, current: current, limit: limit, owner: owner) }
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
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
            let affectedEntryIDs = entries.filter { $0.categoryID == category.id }.map(\.id)
            let oldLimit = category.kind == .expense ?
                categoryBudgets.first(where: { $0.id == CategoryBudget.key(
                    monthKey: CategoryBudget.monthKey(for: .now), categoryName: category.name) }) : nil
            try repository.saveCategory(edited)
            if let accountRepository = repository as? CoreDataLedgerRepository {
                for id in affectedEntryIDs {
                    if let entry = try accountRepository.syncEntry(id: id) { cloud?.upload(entry) }
                }
            }
            if let oldLimit {
                if oldLimit.id != CategoryBudget.key(monthKey: oldLimit.monthKey, categoryName: clean) {
                    let removed = CategoryBudget(monthKey: oldLimit.monthKey,
                                                 categoryName: category.name, amount: 0, updatedAt: .now)
                    try repository.setCategoryBudget(removed)
                    cloud?.upload(removed)
                }
                let moved = CategoryBudget(monthKey: oldLimit.monthKey,
                                           categoryName: clean, amount: oldLimit.amount, updatedAt: .now)
                try repository.setCategoryBudget(moved)
                cloud?.upload(moved)
            }
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

    @discardableResult
    func saveReminder(_ reminder: LedgerReminder) async -> Bool {
        let scope = categoryLearningScope
        let owner = accountID
        guard reminder.isValid else { error = LedgerDataError.invalidReminder.localizedDescription; return false }
        if !reminder.isPaused {
            let allowed = await notifications.requestPermission()
            guard scope == categoryLearningScope else { return false }
            guard allowed else {
                error = "Allow notifications in device Settings before saving an active reminder."
                return false
            }
        }
        do {
            try repository.saveReminder(reminder)
            reload()
            do {
                try await notifications.schedule(reminder, owner: owner)
            } catch {
                if scope == categoryLearningScope {
                    self.error = "Reminder saved, but its notification could not be scheduled: \(error.localizedDescription)"
                }
            }
            return scope == categoryLearningScope
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func setReminderPaused(_ reminder: LedgerReminder, paused: Bool) async {
        var changed = reminder
        changed.isPaused = paused
        _ = await saveReminder(changed)
    }

    func deleteReminder(_ reminder: LedgerReminder) {
        do {
            try repository.deleteReminder(id: reminder.id)
            notifications.cancel(reminder, owner: accountID)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func savePlace(_ place: LedgerPlace) -> Bool {
        do {
            try repository.savePlace(place)
            reload()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func deletePlace(_ place: LedgerPlace) {
        do {
            try repository.deletePlace(id: place.id)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    private func reload(captureLibrary: Bool = true) {
        do {
            entries = try repository.fetchEntries()
            budget = try repository.fetchCurrentBudget()
            categoryBudgets = try repository.fetchCategoryBudgets(
                monthKey: CategoryBudget.monthKey(for: .now))
            lifeEvents = try repository.fetchLifeEvents()
            friends = try repository.fetchFriends()
            splitBills = try repository.fetchSplitBills()
            categories = try repository.fetchCategories()
            refreshCategoryLearning()
            paymentMethods = try repository.fetchPaymentMethods()
            reminders = try repository.fetchReminders()
            places = try repository.fetchPlaces()
            if captureLibrary { library?.capture() }
            refreshBudgetWidget()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func suspendForAccountDeletion(_ uid: String) {
        guard accountID == uid else { return }
        library?.stop(); library = nil
        cloud?.stop()
        personalLearning.cancelTraining()
        cloud = nil
        notifications.cancelAll(reminders, owner: uid)
        finishPendingDeletion()
        uploadingExistingData = false
        syncStatus = "Account deletion pending"
        try? BudgetWidgetPublisher.clear()
        PlaceArrivalMonitor.shared.suspendForAccountDeletion(uid)
    }

    func eraseLocalAccount(_ uid: String, includesClaimedGuest: Bool) throws {
        guard accountID == uid else { throw AccountDeletionError.accountChanged }
        suspendForAccountDeletion(uid)
        guard var pending = try AccountDeletionJournal.shared.load(uid),
              let account = repository as? CoreDataLedgerRepository else {
            throw AccountDeletionError.invalidRecoveryRecord
        }
        var receiptIDs = try account.receiptIDsForAccountDeletion()
        let guest = includesClaimedGuest ? CoreDataLedgerRepository() : nil
        if let guest { receiptIDs.formUnion(try guest.receiptIDsForAccountDeletion()) }
        pending.receiptIDs.formUnion(receiptIDs)
        try AccountDeletionJournal.shared.save(pending)
        let protected = try CoreDataLedgerRepository.protectedReceiptIDs(excluding: uid,
            includeClaimedGuest: includesClaimedGuest)
        try ReceiptImageStore.removeForAccountDeletion(pending.receiptIDs, protected: protected, includesClaimedGuest: includesClaimedGuest)
        try account.eraseForAccountDeletion()
        try guest?.eraseForAccountDeletion()
        try CloudLibraryController.erase(uid)
        try PersonalCategoryStorage.clear(accountID: uid)
        if includesClaimedGuest { try PersonalCategoryStorage.clear(accountID: nil) }
        reload()
    }

    func receiptDidChange(_ id: UUID) {
        do { library?.captureMedia(kind: .receipt, id: id.uuidString, payload: try ReceiptImageStore.archiveForSync(for: id)) }
        catch { self.error = error.localizedDescription }
    }

    func refreshCurrentMonth() { reload() }

    // Enable only after Firebase restores the selected account. Previews and
    // in-memory stores never publish their sample data to a real widget.
    func enableBudgetWidgets() {
        publishesBudgetWidget = true
        refreshBudgetWidget()
    }

    func refreshBudgetWidget() {
        if let accountID, AccountDeletionJournal.shared.contains(accountID) {
            try? BudgetWidgetPublisher.clear()
            return
        }
        guard publishesBudgetWidget else { return }
        do {
            try BudgetWidgetPublisher.publish(budget: budget, entries: entries)
            budgetWidgetError = nil
        } catch {
            budgetWidgetError = "The Home Screen widget could not access its shared budget. Open Ledgerly again to retry."
        }
    }
}
