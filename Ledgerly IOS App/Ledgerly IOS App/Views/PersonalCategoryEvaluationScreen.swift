import SwiftUI
import UniformTypeIdentifiers

private struct LearningEvaluationFile: Identifiable {
    let id = UUID()
    let data: Data
    let filename: String
    let url: URL

    init(data: Data, filename: String) throws {
        self.data = data
        self.filename = filename
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ledgerly-Learning-Export-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        self.url = url
    }
}

private struct LearningEvaluationPreview: View {
    @Environment(\.dismiss) private var dismiss
    let file: LearningEvaluationFile
    @State private var isPresentingExport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("This file contains aggregate evaluation results. Check the preview before choosing where to share or save it.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(file.filename).font(.caption).foregroundStyle(.secondary)
                Text(String(decoding: file.data, as: UTF8.self))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .safeAreaInset(edge: .bottom) {
            FileExportActions(url: file.url, contents: file.data, contentType: .json,
                              isPresenting: $isPresentingExport)
        }
        .navigationTitle("Learning report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }.disabled(isPresentingExport)
            }
        }
        .interactiveDismissDisabled(isPresentingExport)
    }
}

struct PersonalCategoryEvaluationScreen: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var learning: PersonalCategoryLearningController
    let attemptID: UUID
    @State private var accountScope: String
    @State private var ledgerScope: UUID
    @State private var includeCategoryNames = false
    @State private var export: LearningEvaluationFile?
    @State private var exportError: String?

    init(store: LedgerStore, learning: PersonalCategoryLearningController, attemptID: UUID) {
        self.store = store
        self.learning = learning
        self.attemptID = attemptID
        _accountScope = State(initialValue: learning.accountScope)
        _ledgerScope = State(initialValue: store.categoryLearningScope)
    }

    private var attempt: PersonalCategoryAttempt? {
        guard accountScope == learning.accountScope, ledgerScope == store.categoryLearningScope else { return nil }
        return learning.archive.attempts.first { $0.id == attemptID }
    }

    var body: some View {
        Group {
            if let attempt { report(attempt) }
            else {
                ContentUnavailableView("Results unavailable", systemImage: "chart.bar.xaxis",
                    description: Text("This attempt is no longer in recent history, its data was cleared, or you switched accounts. Return to Personal models for current results."))
            }
        }
        .navigationTitle("Category results")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $export) { file in
            NavigationStack {
                if attempt != nil { LearningEvaluationPreview(file: file) }
                else { ContentUnavailableView("Results unavailable", systemImage: "doc.text") }
            }
        }
        .onChange(of: learning.accountScope) { _, _ in
            export = nil
            includeCategoryNames = false
            exportError = nil
        }
        .onChange(of: store.categoryLearningScope) { _, _ in
            export = nil
            includeCategoryNames = false
            exportError = nil
        }
        .onChange(of: learning.archive.attempts.map(\.id)) { _, ids in
            if !ids.contains(attemptID) { export = nil }
        }
        .alert("Could not create report", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: { Text(exportError ?? "Try again.") }
    }

    private func report(_ attempt: PersonalCategoryAttempt) -> some View {
        List {
            Section {
                Label(attempt.kind == 0 ? "Expense model" : attempt.kind == 1 ? "Income model" : "Training attempt",
                      systemImage: "brain").font(.headline)
                LabeledContent("Version", value: String(attempt.id.uuidString.prefix(8)))
                LabeledContent("Checked", value: attempt.date.formatted(date: .abbreviated, time: .shortened))
                Text(attempt.reason).font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Final test") {
                LabeledContent("Transactions checked", value: "\(attempt.metrics.total)")
                LabeledContent("Correct suggestions", value: "\(attempt.metrics.correct) of \(attempt.metrics.suggested)")
                LabeledContent("Asked instead", value: "\(attempt.metrics.total - attempt.metrics.suggested)")
                Text("These results come from the reserved test transactions, not transactions used to train the model. Small samples and repeated tests do not establish future accuracy. Category names reflect your current ledger; the saved counts belong to this attempt.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let corrected = attempt.correctedTrainingExamples, let rows = attempt.weightedTrainingRows {
                Section("Correction weighting") {
                    LabeledContent("Unique training transactions", value: "\(attempt.trainingCount)")
                    LabeledContent("With correction feedback", value: "\(corrected)")
                    LabeledContent("Training rows after 2× weighting", value: "\(rows)")
                    Text("Only the reserved training slice receives repeated correction rows. Calibration, final test and baseline counts use unique transactions. A new model's suggestions require two distinct similar training transactions as well as the confidence checks.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Confidence and correctness") {
                if attempt.metrics.reliability != nil {
                    NavigationLink("View score reliability chart") {
                        PersonalCategoryReliabilityScreen(learning: learning, attemptID: attempt.id)
                    }
                } else {
                    Text("No reliability chart was saved for this attempt. New completed evaluations include it; existing reports stay unchanged.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            calibrationSection(attempt.calibrationCheck)
            Section {
                Toggle("Include category names", isOn: $includeCategoryNames)
                Button("Preview JSON report", systemImage: "doc.text") { prepareExport() }
            } header: { Text("Export evaluation") }
              footer: {
                Text("Includes saved counts, weighting, baselines, category results, score reliability and calibration checks when available. Category names are off by default. Transactions, account details, source examples and model files are excluded. Sharing starts only when you choose it from the preview.")
            }
            if let rows = attempt.metrics.perCategory, !rows.isEmpty {
                Section {
                    Text("Precision shows how often a suggestion for a category was correct. Recall shows how many test transactions in that category were correctly assigned. Asking you to choose lowers recall, even though no wrong suggestion was shown.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    Section {
                        LabeledContent("Training examples", value: "\(row.training)")
                        LabeledContent("Actual test transactions", value: "\(row.actual)")
                        LabeledContent("Suggestions for this category", value: "\(row.predicted)")
                        LabeledContent("Precision", value: rate(row.precision,
                            fraction: "\(row.correct) of \(row.predicted)", unavailable: "No suggestions"))
                        LabeledContent("Recall", value: rate(row.recall,
                            fraction: "\(row.correct) of \(row.actual)", unavailable: "No test examples"))
                        LabeledContent("Asked instead", value: "\(row.abstained) of \(row.actual)")
                        if row.actual == 0 {
                            Text("This test contained no transactions actually labelled with this category. Its recall cannot be measured.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if row.training < 3 {
                            Text("Fewer than three older training examples were available for this category. It was not eligible for personal model training in this attempt.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(row.confusions.keys.sorted(), id: \.self) { predicted in
                            LabeledContent("Suggested as \(name(predicted))", value: "\(row.confusions[predicted, default: 0])")
                        }
                    } header: {
                        Text(name(row.label))
                    }
                }
            } else {
                Section("Per-category results") {
                    Text("No category breakdown was saved for this attempt. New training attempts include it once evaluation completes. Existing results are kept unchanged.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func calibrationSection(_ check: PersonalCategoryCalibrationReport?) -> some View {
        Section {
            if let check {
                Text(check.status.label).font(.headline)
                LabeledContent("Valid calibration examples", value: "\(check.calibrationCount)")
                LabeledContent("Calibration correct / incorrect", value: "\(check.calibrationCorrect) / \(check.calibrationCount - check.calibrationCorrect)")
                LabeledContent("Valid test examples", value: "\(check.testCount)")
                LabeledContent("Test correct / incorrect", value: "\(check.testCorrect) / \(check.testCount - check.testCorrect)")
                LabeledContent("Raw Brier score", value: metric(check.raw.brierScore))
                LabeledContent("Adjusted Brier score", value: metric(check.adjusted?.brierScore))
                LabeledContent("Raw binned score gap", value: metric(check.raw.reliability.binnedGap))
                LabeledContent("Adjusted binned score gap", value: metric(check.adjusted?.reliability.binnedGap))
                if check.calibrationSkipped + check.testSkipped > 0 {
                    Text("Missing or invalid scores excluded: \(check.calibrationSkipped) calibration, \(check.testSkipped) test.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let adjusted = check.adjusted {
                    DisclosureGroup("Adjusted score ranges") {
                        ForEach(adjusted.reliability.bins) { bin in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(bin.index == 4 ? "80–100%" : "\(bin.index * 20) to below \((bin.index + 1) * 20)%")
                                    .font(.headline)
                                Text("\(bin.correct) correct of \(bin.count) predictions")
                                Text("Average estimate \(metric(bin.meanScore)) · correctness \(metric(bin.accuracy))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("The adjustment estimates whether the top category is correct, using all valid scores, including hidden suggestions. It is fitted only on the calibration slice. Lower Brier scores and smaller gaps are better on this test; neither proves future calibration.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Fitting needs 30 valid calibration examples, including five correct and five incorrect predictions. Judging improvement needs 20 valid test examples, including three of each outcome. Improvement means lower Brier score with no larger five-bin gap. These are fixed diagnostic rules, not a statistical guarantee.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("No calibration check was saved for this attempt. New completed training attempts include it.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Experimental calibration check")
        } footer: {
            Text("This check never changes the suggestion gate or model activation. For a current model with a supported improvement check, you can opt in to experimental confidence estimates in Personal models. The adjustment is for display only; the gate uses original model scores.")
        }
    }

    private func metric(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(3))) ?? "Unavailable"
    }

    private func name(_ label: String) -> String {
        guard let id = UUID(uuidString: label), let category = store.categories.first(where: { $0.id == id }) else {
            return "Previous category"
        }
        return category.name + (category.isArchived ? " (archived)" : "")
    }

    private func prepareExport() {
        guard let attempt else { return }
        do {
            let names = Dictionary(uniqueKeysWithValues: store.categories.map {
                ($0.id.uuidString, $0.name + ($0.isArchived ? " (archived)" : ""))
            })
            let report = PersonalCategoryEvaluationExport(attempt: attempt, categoryNames: names,
                includeCategoryNames: includeCategoryNames)
            export = try LearningEvaluationFile(data: report.jsonData(),
                filename: "Ledgerly-learning-\(attempt.id.uuidString.prefix(8)).json")
        } catch { exportError = "Could not prepare the report. Check available storage and try again." }
    }

    private func rate(_ value: Double?, fraction: String, unavailable: String) -> String {
        guard let value else { return unavailable }
        return "\(value.formatted(.percent.precision(.fractionLength(0)))) · \(fraction)"
    }
}
