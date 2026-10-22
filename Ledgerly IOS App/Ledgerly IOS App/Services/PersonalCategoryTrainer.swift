import Foundation
import CoreML

nonisolated final class PersonalCategoryPredictor: @unchecked Sendable {
    let record: PersonalCategoryModelRecord
    private let model: MLModel
    private let vectors: [[Double]]
    private let lock = NSLock()

    init(record: PersonalCategoryModelRecord, url: URL) throws {
        guard record.correctionWeightingVersion == nil || record.correctionWeightingVersion == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.record = record
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: url, configuration: configuration)
        vectors = record.training.map { PersonalCategoryPolicy.features($0.text) }
    }

    func score(text: String, expected: String = "") throws -> PersonalCategoryScore {
        try evaluate(text: text, expected: expected).score
    }

    func evaluate(text: String, expected: String = "") throws -> (score: PersonalCategoryScore, ranked: [CategoryRankedScore]) {
        let vector = PersonalCategoryPolicy.features(text)
        let input = try PersonalCategoryTrainer.input(vector)
        lock.lock()
        defer { lock.unlock() }
        let output = try model.prediction(from: input)
        let probabilities = output.featureValue(for: model.modelDescription.predictedProbabilitiesName ?? "categoryProbs")?.dictionaryValue ?? [:]
        let ranked = probabilities.compactMap { key, value -> (String, Double)? in
            guard let label = key as? String else { return nil }
            return (label, value.doubleValue)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        let best = ranked.first
        let similarities = vectors.map { PersonalCategoryPolicy.similarity(vector, $0) }
        let nearest = similarities.max() ?? 0
        let independentSupport: Int?
        if record.correctionWeightingVersion == 1, let label = best?.0 {
            independentSupport = Set(zip(record.training, similarities).compactMap { example, similarity in
                example.label == label && similarity >= PersonalCategoryPolicy.minimumSimilarity
                    ? example.id : nil
            }).count
        } else { independentSupport = nil }
        let score = PersonalCategoryScore(expected: expected, predicted: best?.0, confidence: best?.1 ?? 0,
                     margin: (best?.1 ?? 0) - (ranked.dropFirst().first?.1 ?? 0), similarity: nearest,
                     independentSupport: independentSupport)
        var similarityByLabel: [String: Double] = [:]
        for (example, similarity) in zip(record.training, similarities) {
            similarityByLabel[example.label] = max(similarityByLabel[example.label] ?? 0, similarity)
        }
        return (score, ranked.map { .init(label: $0.0, score: $0.1, similarity: similarityByLabel[$0.0] ?? 0) })
    }
}

nonisolated enum PersonalCategoryStorage {
    static func folder(accountID: String?) -> URL {
        let key = Data((accountID ?? "guest").utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersonalCategoryModels").appendingPathComponent(key)
    }

    static func load(from folder: URL) throws -> PersonalCategoryArchive {
        let url = folder.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let archive = try JSONDecoder().decode(PersonalCategoryArchive.self, from: Data(contentsOf: url))
        guard archive.schema == 1,
              Set(archive.models.map(\.kind)).count == archive.models.count,
              archive.models.allSatisfy({ [Int16(0), 1].contains($0.kind) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return archive
    }

    static func save(_ archive: PersonalCategoryArchive, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var privateFolder = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try privateFolder.setResourceValues(values)
        let url = folder.appendingPathComponent("history.json")
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func clear(accountID: String?) throws {
        let directory = folder(accountID: accountID)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    /// Removing or changing a labelled example invalidates every model that could have learned it.
    static func invalidate(_ archive: PersonalCategoryArchive, at folder: URL) throws -> PersonalCategoryArchive {
        var cleared = archive
        cleared.models = []
        cleared.sourceExamples = []
        cleared.calibratedEstimateVersions = nil
        try save(cleared, to: folder)
        for model in archive.models {
            let url = folder.appendingPathComponent(model.version.uuidString).appendingPathExtension("mlmodelc")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        return cleared
    }
}

nonisolated enum PersonalCategoryTrainer {
    struct Result: Sendable {
        let staging: URL
        let models: [PersonalCategoryModelRecord]
        let predictors: [Int16: PersonalCategoryPredictor]
        let attempts: [PersonalCategoryAttempt]
    }

    static func input(_ values: [Double]) throws -> MLDictionaryFeatureProvider {
        let array = try MLMultiArray(shape: [NSNumber(value: values.count)], dataType: .float32)
        for (index, value) in values.enumerated() { array[index] = NSNumber(value: value) }
        return try MLDictionaryFeatureProvider(dictionary: ["features": MLFeatureValue(multiArray: array)])
    }

    static func predictors(archive: PersonalCategoryArchive, folder: URL) throws -> [Int16: PersonalCategoryPredictor] {
        try Dictionary(uniqueKeysWithValues: archive.models.map { record in
            (record.kind, try PersonalCategoryPredictor(record: record,
                url: folder.appendingPathComponent(record.version.uuidString).appendingPathExtension("mlmodelc")))
        })
    }

    static func train(examples: [PersonalCategoryExample], seed: URL,
                      previous: [Int16: PersonalCategoryPredictor], stagingRoot: URL? = nil) async throws -> Result {
        let staging = (stagingRoot ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("ledgerly-training-\(UUID())")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: staging) } }
        var models: [PersonalCategoryModelRecord] = []
        var predictors: [Int16: PersonalCategoryPredictor] = [:]
        var attempts: [PersonalCategoryAttempt] = []
        for kind: Int16 in [0, 1] {
            try Task.checkCancellation()
            guard let split = PersonalCategoryPolicy.split(examples, kind: kind) else { continue }
            let version = UUID()
            let url = staging.appendingPathComponent(version.uuidString).appendingPathExtension("mlmodelc")
            let updateRows = PersonalCategoryPolicy.updateExamples(for: split)
            try await update(seed: seed, examples: updateRows, destination: url)
            try Task.checkCancellation()
            let temporaryRecord = PersonalCategoryModelRecord(version: version, kind: kind, threshold: 1,
                training: split.training, correctionWeightingVersion: 1)
            let predictor = try PersonalCategoryPredictor(record: temporaryRecord, url: url)
            let calibration = try split.calibration.map { try predictor.score(text: $0.text, expected: $0.label) }
            let count = examples.filter { $0.kind == kind }.count
            let threshold = PersonalCategoryPolicy.threshold(calibration: calibration, exampleCount: count)
            let scores = try split.test.map { try predictor.score(text: $0.text, expected: $0.label) }
            let metrics = PersonalCategoryPolicy.metrics(scores: scores, threshold: threshold ?? 2,
                training: split.training, test: split.test)
            var previousMetrics: PersonalCategoryMetrics?
            var comparable = true
            if let old = previous[kind] {
                let oldIDs = Set(old.record.training.map(\.id))
                comparable = !split.test.contains { oldIDs.contains($0.id) }
                if comparable {
                    let oldScores = try split.test.map { try old.score(text: $0.text, expected: $0.label) }
                    previousMetrics = PersonalCategoryPolicy.metrics(scores: oldScores, threshold: old.record.threshold,
                        training: old.record.training, test: split.test)
                }
            }
            let accepted = comparable && threshold != nil &&
                PersonalCategoryPolicy.canActivate(metrics, previous: previousMetrics)
            let reason: String
            if !comparable { reason = "Kept the previous model: current test examples were already used by it. Add newer transactions before comparing again." }
            else if threshold == nil { reason = "No confidence gate met the calibration target with at least five suggestions." }
            else if metrics.suggested == 0 { reason = "No reliable suggestions on the final test slice; kept the previous model." }
            else if accepted { reason = "Activated after a time-ordered test. Small samples do not guarantee future accuracy." }
            else { reason = "Kept the previous model: test precision missed the target or was lower than the previous model on the same test." }
            attempts.append(.init(id: version, date: .now, kind: kind, exampleCount: count,
                trainingCount: split.training.count, calibrationCount: split.calibration.count,
                threshold: threshold, metrics: metrics, activated: accepted, reason: reason,
                correctedTrainingExamples: split.training.filter { $0.correctionDate != nil }.count,
                weightedTrainingRows: updateRows.count,
                calibrationCheck: PersonalCategoryCalibration.evaluate(calibration: calibration, test: scores)))
            if accepted, let threshold {
                let record = PersonalCategoryModelRecord(version: version, kind: kind, threshold: threshold,
                    training: split.training, correctionWeightingVersion: 1)
                models.append(record)
                predictors[kind] = try PersonalCategoryPredictor(record: record, url: url)
            } else { try FileManager.default.removeItem(at: url) }
        }
        succeeded = true
        return Result(staging: staging, models: models, predictors: predictors, attempts: attempts)
    }

    private static func update(seed: URL, examples: [PersonalCategoryExample], destination: URL) async throws {
        let rows = try examples.map { example -> MLFeatureProvider in
            let features = try input(PersonalCategoryPolicy.features(example.text))
            return try MLDictionaryFeatureProvider(dictionary: [
                "features": features.featureValue(for: "features")!, "category": example.label
            ])
        }
        let control = UpdateControl()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    let configuration = MLModelConfiguration()
                    configuration.computeUnits = .cpuOnly
                    let task = try MLUpdateTask(forModelAt: seed, trainingData: MLArrayBatchProvider(array: rows),
                        configuration: configuration) { context in
                        defer { control.finish() }
                        do {
                            if control.isCancelled { throw CancellationError() }
                            if let error = context.task.error { throw error }
                            guard context.task.state == .completed else { throw CocoaError(.userCancelled) }
                            try context.model.write(to: destination)
                            continuation.resume()
                        } catch { continuation.resume(throwing: error) }
                    }
                    control.start(task)
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { control.cancel() }
    }

    private final class UpdateControl: @unchecked Sendable {
        private let lock = NSLock()
        private var task: MLUpdateTask?
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func start(_ task: MLUpdateTask) {
            lock.withLock {
                self.task = task
            }
            task.resume()
            if isCancelled { task.cancel() }
        }
        func cancel() {
            let pending = lock.withLock { cancelled = true; return task }
            pending?.cancel()
        }
        func finish() { lock.withLock { task = nil } }
    }
}
