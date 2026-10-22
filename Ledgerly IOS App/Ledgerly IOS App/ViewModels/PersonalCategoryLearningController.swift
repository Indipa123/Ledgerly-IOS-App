import Foundation
import Combine

@MainActor
final class PersonalCategoryLearningController: ObservableObject {
    @Published private(set) var status = "Save more transactions to personalise suggestions."
    @Published private(set) var isTraining = false
    @Published private(set) var isLoading = false
    @Published private(set) var archive = PersonalCategoryArchive()
    @Published private(set) var examples: [PersonalCategoryExample] = []
    @Published private(set) var automaticStatus = "Automatic updates are off."
    private var predictors: [Int16: PersonalCategoryPredictor] = [:]
    private var accountID: String?
    private var selectedAccount = false
    private var persistenceEnabled = true
    private var blocked = false
    private var storageHealthy = true
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var automaticTask: Task<Void, Never>?
    private var automaticQueueID = UUID()
    private var workspaceIdle = false
    private var workspaceAvailable: (() -> Bool)?
    private var categoryRevision = ""
    private var editorIDs: Set<UUID> = []
    private var trainingAutomatically = false
    private var suppressedExamples: [PersonalCategoryExample]?
    private var pendingCorrections: Set<UUID> = []
    var accountScope: String { accountID ?? "guest" }
    var automaticEnabled: Bool { archive.automation?.enabled == true }
    var pendingExampleCount: Int {
        Set(examples.map(\.id)).subtracting(archive.automation?.checkpointIDs ?? []).count
    }
    var pendingCorrectionCount: Int {
        (archive.automation?.correctionIDs ?? []).intersection(examples.map(\.id)).count
    }

    var canTrain: Bool {
        persistenceEnabled && storageHealthy && !blocked && !isTraining && !isLoading && editorIDs.isEmpty &&
        [Int16(0), 1].contains { PersonalCategoryPolicy.split(examples, kind: $0) != nil }
    }

    func synchronize(accountID: String?, examples: [PersonalCategoryExample], categoryRevision: String,
                     persistent: Bool, blocked: Bool) {
        persistenceEnabled = persistent
        self.blocked = blocked
        if blocked {
            cancelTraining()
            predictors = [:]
            status = "Learning is paused while account deletion is pending."
            return
        }
        if !selectedAccount || self.accountID != accountID {
            cancelTraining()
            selectedAccount = true
            self.accountID = accountID
            self.examples = examples
            self.categoryRevision = categoryRevision
            suppressedExamples = nil
            pendingCorrections = []
            storageHealthy = true
            archive = .init()
            predictors = [:]
            guard persistent else { return }
            let token = generation
            let folder = PersonalCategoryStorage.folder(accountID: accountID)
            isLoading = true
            task = Task {
                do {
                    let loaded = try await Task.detached(priority: .utility) {
                        let saved = try PersonalCategoryStorage.load(from: folder)
                        return (saved, try PersonalCategoryTrainer.predictors(archive: saved, folder: folder))
                    }.value
                    guard generation == token, !Task.isCancelled else { return }
                    isLoading = false
                    archive = loaded.0
                    if archive.isValid(for: self.examples) {
                        predictors = loaded.1
                        status = predictors.isEmpty ? "Save more transactions to get started." : "Personalised suggestions are ready."
                    } else { invalidateModels() }
                    applyPendingCorrections()
                    refreshAutomaticSchedule()
                } catch {
                    guard generation == token else { return }
                    isLoading = false
                    storageHealthy = false
                    status = "Personalised suggestions are unavailable. Your saved category choices still work. Try resetting suggestions."
                    refreshAutomaticSchedule()
                }
            }
        } else if self.examples != examples || self.categoryRevision != categoryRevision {
            if isTraining { cancelTraining() }
            self.examples = examples
            self.categoryRevision = categoryRevision
            suppressedExamples = nil
            if !archive.isValid(for: examples) { invalidateModels() }
            cancelAutomaticQueue()
            refreshAutomaticSchedule()
        }
    }

    func setAutomatic(_ enabled: Bool) {
        guard persistenceEnabled, !isLoading, storageHealthy, !blocked else { return }
        var updated = archive
        var state = updated.automation ?? .init()
        if state.lastAttemptAt == nil, let last = archive.attempts.last {
            state.completed(exampleIDs: Set(examples.map(\.id)), revision: categoryRevision, at: last.date)
        }
        state.enabled = enabled
        updated.automation = state
        do {
            try PersonalCategoryStorage.save(updated, to: PersonalCategoryStorage.folder(accountID: accountID))
            archive = updated
            suppressedExamples = nil
            cancelAutomaticQueue()
            if !enabled && isTraining && trainingAutomatically { cancelTraining() }
            refreshAutomaticSchedule()
        } catch { status = "Could not save your learning preferences. Try again." }
    }

    /// Only a successfully saved local category edit calls this; cloud callbacks never do.
    func recordCorrection(entryID: UUID) {
        guard examples.contains(where: { $0.id == entryID }) else { return }
        pendingCorrections.insert(entryID)
        if !isLoading { applyPendingCorrections(); refreshAutomaticSchedule() }
    }

    private func applyPendingCorrections() {
        guard !pendingCorrections.isEmpty else { return }
        var updated = archive
        var state = updated.automation ?? .init()
        state.correctionIDs.formUnion(pendingCorrections)
        updated.automation = state
        do {
            if persistenceEnabled { try PersonalCategoryStorage.save(updated, to: PersonalCategoryStorage.folder(accountID: accountID)) }
            archive = updated
            pendingCorrections = []
        } catch { status = "Transaction saved. Learning will update later." }
    }

    func setWorkspaceIdle(_ idle: Bool, availability: (() -> Bool)? = nil) {
        if let availability { workspaceAvailable = availability }
        workspaceIdle = idle
        if !idle {
            cancelAutomaticQueue()
            if isTraining && trainingAutomatically { cancelTraining() }
        }
        refreshAutomaticSchedule()
    }

    func editorOpened(_ id: UUID) {
        editorIDs.insert(id)
        cancelAutomaticQueue()
        if isTraining { cancelTraining() }
        refreshAutomaticSchedule()
    }

    func editorClosed(_ id: UUID) {
        editorIDs.remove(id)
        refreshAutomaticSchedule()
    }

    private func cancelAutomaticQueue() {
        automaticQueueID = UUID()
        automaticTask?.cancel()
        automaticTask = nil
    }

    private func refreshAutomaticSchedule() {
        guard automaticEnabled else { automaticStatus = "Automatic updates are off."; return }
        guard workspaceIdle, workspaceAvailable?() == true, editorIDs.isEmpty, !blocked,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            cancelAutomaticQueue()
            if isTraining && trainingAutomatically { cancelTraining() }
            automaticStatus = "Updates resume when Ledgerly is open and Low Power Mode is off."
            return
        }
        guard !isTraining, !isLoading else { automaticStatus = "Updating suggestions…"; return }
        guard suppressedExamples != examples else {
            automaticStatus = "Update cancelled. Save more transactions or choose Update suggestions now."
            return
        }
        guard canTrain else { automaticStatus = "Waiting for enough saved transactions to update suggestions."; return }
        guard PersonalRetrainingPolicy.reason(state: archive.automation ?? .init(),
            exampleIDs: Set(examples.map(\.id)), revision: categoryRevision, hasTrainableData: true) != nil else {
            automaticStatus = "Up to date."
            return
        }
        automaticStatus = "An update will start while Ledgerly is open."
        guard automaticTask == nil else { return }
        let token = automaticQueueID
        automaticTask = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard token == automaticQueueID, !Task.isCancelled else { return }
            automaticTask = nil
            guard workspaceIdle, workspaceAvailable?() == true, editorIDs.isEmpty, automaticEnabled, canTrain,
                  !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
            retrain(automatically: true)
        }
    }

    func hasModel(for kind: EntryKind) -> Bool { predictors[kind.rawValue] != nil }

    func calibrationAvailable(for model: PersonalCategoryModelRecord) -> Bool {
        !blocked && storageHealthy && predictors[model.kind]?.record.version == model.version &&
            PersonalCategoryCalibrationDeployment.isEligible(model: model,
                attempt: archive.attempts.first { $0.id == model.version })
    }

    func calibratedEstimatesEnabled(for model: PersonalCategoryModelRecord) -> Bool {
        calibrationAvailable(for: model) && archive.calibratedEstimateVersions?.contains(model.version) == true
    }

    func setCalibratedEstimates(_ enabled: Bool, for version: UUID) {
        guard persistenceEnabled, storageHealthy, !blocked, !isLoading, !isTraining,
              let model = archive.models.first(where: { $0.version == version }),
              !enabled || calibrationAvailable(for: model) else { return }
        var updated = archive
        var approved = updated.calibratedEstimateVersions ?? []
        if enabled { approved.insert(version) } else { approved.remove(version) }
        updated.calibratedEstimateVersions = approved
        do {
            try PersonalCategoryStorage.save(updated, to: PersonalCategoryStorage.folder(accountID: accountID))
            archive = updated
            status = enabled ? "Experimental confidence estimates enabled." :
                "Experimental confidence estimates turned off for this model version."
        } catch { status = "Could not save confidence preferences. Try again." }
    }

    func suggestion(title: String, kind: EntryKind, categories: [LedgerCategory]) -> CategoryMemorySuggestion? {
        assistance(title: title, kind: kind, categories: categories).suggestion
    }

    func assistance(title: String, kind: EntryKind, categories: [LedgerCategory]) -> CategoryAssistance {
        guard !blocked, let predictor = predictors[kind.rawValue],
              CategorySuggestionPolicy.hasDistinctiveDescription(title),
              let result = try? predictor.evaluate(text: CategoryMemoryIndex.normalized(title)) else { return .init() }
        let score = result.score
        guard PersonalCategoryPolicy.accepts(score, threshold: predictor.record.threshold),
              let label = score.predicted, let id = UUID(uuidString: label),
              categories.contains(where: { $0.id == id && $0.kind == kind && !$0.isArchived }) else {
            return .init(alternatives: CategorySuggestionPolicy.alternatives(scores: result.ranked,
                title: title, kind: kind, activeCategories: categories, source: .personalModel,
                modelVersion: predictor.record.version))
        }
        return .init(suggestion: .init(categoryID: id,
            exampleCount: predictor.record.training.filter { $0.label == label }.count,
            match: .personalModel, modelVersion: predictor.record.version,
            estimatedCorrectness: PersonalCategoryCalibrationDeployment.estimate(score: score,
                model: predictor.record, attempt: archive.attempts.first { $0.id == predictor.record.version },
                approvedVersions: archive.calibratedEstimateVersions ?? [])))
    }

    func retrain(automatically: Bool = false) {
        guard canTrain, !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            if ProcessInfo.processInfo.isLowPowerModeEnabled { status = "Turn off Low Power Mode to update suggestions." }
            return
        }
        guard let seed = Bundle.main.url(forResource: "PersonalCategorySeed", withExtension: "mlmodelc") else {
            suppressedExamples = examples
            status = "Personalised updates are unavailable. Your saved category choices still work."
            return
        }
        cancelAutomaticQueue()
        suppressedExamples = nil
        trainingAutomatically = automatically
        let trigger = automatically ? "Automatic: " + (PersonalRetrainingPolicy.reason(
            state: archive.automation ?? .init(), exampleIDs: Set(examples.map(\.id)),
            revision: categoryRevision, hasTrainableData: true)?.rawValue ?? "New data") : "Manual"
        let token = generation
        let snapshot = examples
        let previous = predictors
        let folder = PersonalCategoryStorage.folder(accountID: accountID)
        do { try PersonalCategoryStorage.save(archive, to: folder) }
        catch { storageHealthy = false; status = "Could not start the update. Check available device storage and try again."; return }
        isTraining = true
        status = "Updating suggestions on this device…"
        task = Task {
            let worker = Task.detached(priority: .utility) {
                try await PersonalCategoryTrainer.train(examples: snapshot, seed: seed, previous: previous,
                    stagingRoot: folder.appendingPathComponent("Training"))
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                defer { try? FileManager.default.removeItem(at: result.staging) }
                guard generation == token, !Task.isCancelled, snapshot == examples, !blocked,
                      !AccountDeletionJournal.shared.blocks(owner: accountID) else { return }
                if automatically && (!workspaceIdle || workspaceAvailable?() != true || !editorIDs.isEmpty ||
                    ProcessInfo.processInfo.isLowPowerModeEnabled) {
                    cancelTraining()
                    refreshAutomaticSchedule()
                    return
                }
                try commit(result, snapshot: snapshot, trigger: trigger)
                isTraining = false
                status = result.models.isEmpty ? "Update checked. Keeping your existing suggestions."
                    : "Personalised suggestions updated."
                refreshAutomaticSchedule()
            } catch {
                guard generation == token else { return }
                isTraining = false
                if !(error is CancellationError) {
                    var failed = archive
                    var state = failed.automation ?? .init()
                    state.completed(exampleIDs: Set(snapshot.map(\.id)), revision: categoryRevision, at: .now)
                    failed.automation = state
                    failed.attempts = Array((failed.attempts + [.init(id: UUID(), date: .now, kind: -1,
                        exampleCount: snapshot.count, trainingCount: 0, calibrationCount: 0, threshold: nil,
                        metrics: .init(), activated: false, reason: "Training failed; no replacement was published.",
                        trigger: trigger)]).suffix(10))
                    if (try? PersonalCategoryStorage.save(failed, to: PersonalCategoryStorage.folder(accountID: accountID))) != nil {
                        archive = failed
                    } else { storageHealthy = false }
                }
                status = error is CancellationError ? "Update cancelled. Your existing suggestions are unchanged."
                    : "Could not update suggestions. Your existing suggestions are unchanged. Try again."
                refreshAutomaticSchedule()
            }
        }
    }

    func cancelTraining(suppressAutomatic: Bool = false) {
        cancelAutomaticQueue()
        if suppressAutomatic { suppressedExamples = examples }
        generation = UUID()
        task?.cancel()
        // Retain the task until a replacement is started so account deletion can await its cleanup.
        if isTraining { status = "Update cancelled. Your existing suggestions are unchanged." }
        isTraining = false
        isLoading = false
        if suppressAutomatic { refreshAutomaticSchedule() }
    }

    func clearAll() {
        let pending = task
        cancelTraining()
        predictors = [:]
        archive = .init()
        pendingCorrections = []
        automaticStatus = "Automatic updates are off."
        let token = generation
        let owner = accountID
        let persistent = persistenceEnabled
        isLoading = true
        status = "Resetting personalised suggestions…"
        task = Task {
            // Wait for the cancelled Core ML callback before removing its account's staging files.
            await pending?.value
            do {
                if persistent { try PersonalCategoryStorage.clear(accountID: owner) }
                guard generation == token else { return }
                storageHealthy = true
                isLoading = false
                status = "Personalised suggestions reset. Your transactions are unchanged."
            } catch {
                guard generation == token else { return }
                storageHealthy = false
                isLoading = false
                status = "Suggestions are paused. Try resetting again to finish cleanup."
            }
        }
    }

    func stopAndWait() async {
        let pending = task
        cancelTraining()
        await pending?.value
    }

    private func invalidateModels() {
        predictors = [:]
        do {
            archive = try PersonalCategoryStorage.invalidate(archive, at: PersonalCategoryStorage.folder(accountID: accountID))
            status = "Your saved choices changed. Update suggestions when ready."
        } catch {
            storageHealthy = false
            status = "Personalised suggestions are paused. Reset them before updating."
        }
    }

    private func commit(_ result: PersonalCategoryTrainer.Result, snapshot: [PersonalCategoryExample], trigger: String) throws {
        let folder = PersonalCategoryStorage.folder(accountID: accountID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var updated = archive
        let replacedKinds = Set(result.models.map(\.kind))
        updated.models.removeAll { replacedKinds.contains($0.kind) }
        updated.models.append(contentsOf: result.models)
        if !result.models.isEmpty { updated.sourceExamples = snapshot }
        let attempts = result.attempts.map { attempt in
            var labelled = attempt
            labelled.trigger = trigger
            return labelled
        }
        updated.attempts = Array((updated.attempts + attempts).suffix(10))
        updated.calibratedEstimateVersions = PersonalCategoryCalibrationDeployment.retainingApprovals(
            updated.calibratedEstimateVersions ?? [], models: updated.models, attempts: updated.attempts)
        var state = updated.automation ?? .init()
        state.completed(exampleIDs: Set(snapshot.map(\.id)), revision: categoryRevision, at: .now)
        updated.automation = state
        var moved: [URL] = []
        do {
            for record in result.models {
                let name = record.version.uuidString + ".mlmodelc"
                let destination = folder.appendingPathComponent(name)
                try FileManager.default.moveItem(at: result.staging.appendingPathComponent(name), to: destination)
                moved.append(destination)
            }
            // The atomic manifest publishes only completely written models.
            try PersonalCategoryStorage.save(updated, to: folder)
        } catch {
            for url in moved { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        for record in archive.models where replacedKinds.contains(record.kind) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(record.version.uuidString + ".mlmodelc"))
        }
        archive = updated
        for (kind, predictor) in result.predictors { predictors[kind] = predictor }
    }
}
