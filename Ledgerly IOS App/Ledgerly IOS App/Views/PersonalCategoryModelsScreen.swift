import SwiftUI

struct PersonalCategoryModelsScreen: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var learning: PersonalCategoryLearningController
    @State private var clearing = false
    @State private var clearScope: String?

    var body: some View {
        List {
            Section {
                Text("Improve category suggestions using your saved choices. Learning happens on this device.")
                    .foregroundStyle(.secondary)
                Text(learning.status)
                if learning.isTraining || learning.isLoading { ProgressView() }
            }
            Section {
                Toggle("Improve suggestions automatically", isOn: Binding(
                    get: { learning.automaticEnabled }, set: { learning.setAutomatic($0) }))
                    .disabled(learning.isLoading)
                Button("Update suggestions now", systemImage: "arrow.triangle.2.circlepath") { learning.retrain() }
                    .disabled(!learning.canTrain)
                if learning.isTraining {
                    Button("Cancel update", role: .cancel) { learning.cancelTraining(suppressAutomatic: true) }
                }
            } footer: {
                Text("Updates become available as you save more transactions. You can always choose a category yourself.")
            }
            if !learning.archive.models.isEmpty {
                Section("Personalised suggestions") {
                    ForEach(learning.archive.models, id: \.version) { model in
                        Label(model.kind == 0 ? "Expenses ready" : "Income ready", systemImage: "checkmark.circle")
                    }
                }
            }
            Section {
                DisclosureGroup("Advanced") {
                    NavigationLink("Advanced learning details") {
                        PersonalCategoryDiagnosticsScreen(store: store, learning: learning)
                    }
                }
            }
            Section {
                Button("Reset personalised suggestions", role: .destructive) {
                    clearScope = learning.accountScope
                    clearing = true
                }
            } footer: {
                Text("Keeps your transactions and saved category choices.")
            }
        }
        .navigationTitle("Personalise suggestions")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Reset personalised suggestions?", isPresented: $clearing) {
            Button("Reset suggestions", role: .destructive) {
                if clearScope == learning.accountScope { learning.clearAll() }
                clearScope = nil
            }
            Button("Cancel", role: .cancel) { clearScope = nil }
        } message: {
            Text("Your transactions and their categories stay saved. Learning can start again when you choose.")
        }
        .onChange(of: learning.accountScope) { _, _ in clearing = false; clearScope = nil }
    }
}

private struct PersonalCategoryDiagnosticsScreen: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var learning: PersonalCategoryLearningController
    @State private var clearing = false
    @State private var clearScope: String?
    @State private var showingTechnicalDetails = false

    var body: some View {
        List {
            Section {
                Label("Personalised suggestions", systemImage: "brain")
                    .font(.headline)
                Text("Ledgerly learns from the categories you choose. Learning stays on this device.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(learning.status).font(.subheadline)
                if learning.isTraining || learning.isLoading { ProgressView() }
            }
            Section {
                Button("Update suggestions now", systemImage: "arrow.triangle.2.circlepath") { learning.retrain() }
                    .disabled(!learning.canTrain)
                if learning.isTraining {
                    Button("Cancel update", role: .cancel) { learning.cancelTraining(suppressAutomatic: true) }
                }
            } footer: {
                Text("Save transactions with descriptions and categories to help Ledgerly learn. You always confirm a category before saving.")
            }
            Section {
                Toggle("Show technical details", isOn: $showingTechnicalDetails)
            } footer: {
                Text("Optional learning statistics and evaluation results.")
            }
            if showingTechnicalDetails {
                Section("Training examples") {
                    LabeledContent("Expenses", value: "\(learning.examples.filter { $0.kind == 0 }.count)")
                    LabeledContent("Income", value: "\(learning.examples.filter { $0.kind == 1 }.count)")
                    LabeledContent("With local correction feedback",
                                   value: "\(learning.examples.filter { $0.correctionDate != nil }.count)")
                    Text("Each type needs at least 15 described transactions, with at least three older examples in each of two categories. Future-dated, excluded and archived-category examples are left out. The most recent 2,000 examples of each type are considered.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Correction-aware training") {
                    Text("New personal models give 2× training weight to local category changes and saved choices that differed from a displayed suggestion. A correction enters the time split when you make it, so later feedback cannot train an earlier test.")
                    Text("Suggestions from new models need support from two distinct similar training transactions. Repeated training rows do not count as extra transactions or evaluation examples. Your next retraining attempt shows its actual counts; existing models keep their saved policy.")
                }
                .font(.footnote).foregroundStyle(.secondary)
                Section("Automatic retraining") {
                    Toggle("Update personal models automatically", isOn: Binding(
                        get: { learning.automaticEnabled }, set: { learning.setAutomatic($0) }))
                        .disabled(learning.isLoading)
                    Text(learning.automaticStatus).font(.subheadline).foregroundStyle(.secondary)
                    if learning.automaticEnabled {
                        LabeledContent("New examples since last attempt", value: "\(learning.pendingExampleCount)")
                        LabeledContent("Corrected transactions", value: "\(learning.pendingCorrectionCount)")
                    }
                    Text("Optional and local to this account. Runs in the open, unlocked workspace after 10 new examples, three distinct transactions whose category you corrected, a category change, or seven days with new examples. Low Power Mode, editors and dialogs pause it. The first model is queued once enough examples exist. Each completed or failed attempt resets the counters so unchanged data is not trained repeatedly.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Active models") {
                    if learning.archive.models.isEmpty {
                        Text("No personal model has passed evaluation yet. Saved-choice matching and the bundled model remain available.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(learning.archive.models, id: \.version) { model in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.kind == 0 ? "Expenses" : "Income").font(.headline)
                            Text("Version \(model.version.uuidString.prefix(8)) · \(model.training.count) training examples")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Toggle("Show experimental confidence", isOn: Binding(
                                get: { learning.calibratedEstimatesEnabled(for: model) },
                                set: { learning.setCalibratedEstimates($0, for: model.version) }))
                                .disabled(!learning.calibrationAvailable(for: model) || learning.isLoading || learning.isTraining)
                            Text(learning.calibrationAvailable(for: model)
                                ? "Optional estimates for this version only. A replacement starts with estimates off."
                                : "Unavailable: this version needs a supported calibration check with enough examples and improved test results.")
                                .font(.footnote).foregroundStyle(.secondary)
                            if let attempt = learning.archive.attempts.first(where: { $0.id == model.version }) {
                                Text(attempt.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.footnote).foregroundStyle(.secondary)
                                NavigationLink("View category results") {
                                    PersonalCategoryEvaluationScreen(store: store, learning: learning, attemptID: attempt.id)
                                }
                            }
                        }
                    }
                }
                Section("About experimental confidence") {
                    Text("When enabled for an eligible model, a suggested category can show an estimated chance of being correct. It is fitted to older calibration examples and checked on a separate later test. The check uses all valid top-category predictions, including those the app would hide.")
                    Text("Small samples and repeated tests do not establish future accuracy. The estimate does not change which suggestions appear or choose a category for you. Confirm the category before saving. Saved-choice and bundled-model suggestions do not receive these estimates.")
                }
                .font(.footnote).foregroundStyle(.secondary)
                Section {
                    Text("Examples available earlier train the model; a later slice selects the confidence gate; the newest slice tests it. Corrections become available when made. With fewer than 50 examples, the gate stays at its most conservative setting. Larger samples must reach 90% precision on at least five calibration suggestions. A replacement must also meet the test target and keep or improve precision against the previous model on the same test.")
                    Text("These are small retrospective checks, not a promise of future accuracy. Repeated checks reuse reserved transactions. Unfamiliar or uncertain descriptions still ask you to choose. Editing or excluding a source example clears affected personal models; retrain to rebuild them.")
                } header: { Text("How evaluation works") }
                  .font(.footnote).foregroundStyle(.secondary)
                Section("Recent training attempts") {
                    if learning.archive.attempts.isEmpty { Text("No training attempts yet.").foregroundStyle(.secondary) }
                    ForEach(learning.archive.attempts.reversed()) { attempt in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(attempt.kind == 0 ? "Expenses" : attempt.kind == 1 ? "Income" : "Training") · \(attempt.activated ? "Activated" : "No replacement")")
                                .font(.headline)
                            Text(attempt.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote).foregroundStyle(.secondary)
                            if let trigger = attempt.trigger {
                                Text(trigger).font(.footnote).foregroundStyle(.secondary)
                            }
                            LabeledContent("Train / calibration / test",
                                value: "\(attempt.trainingCount) / \(attempt.calibrationCount) / \(attempt.metrics.total)")
                            if let corrected = attempt.correctedTrainingExamples, let rows = attempt.weightedTrainingRows {
                                LabeledContent("Corrected training transactions", value: "\(corrected)")
                                LabeledContent("Training rows after weighting", value: "\(rows)")
                            }
                            LabeledContent("Correct suggestions", value: "\(attempt.metrics.correct) of \(attempt.metrics.suggested)")
                            LabeledContent("Test coverage", value: attempt.metrics.coverage.formatted(.percent.precision(.fractionLength(0))))
                            LabeledContent("Precision", value: attempt.metrics.accuracy.map {
                                $0.formatted(.percent.precision(.fractionLength(0)))
                            } ?? "No suggestions")
                            LabeledContent("Exact lookup baseline", value: "\(attempt.metrics.exactCorrect) of \(attempt.metrics.exactSuggested) suggested")
                            LabeledContent("Most common baseline", value: "\(attempt.metrics.majorityCorrect) of \(attempt.metrics.total)")
                            Text(attempt.reason).font(.footnote).foregroundStyle(.secondary)
                            NavigationLink("View evaluation and category results") {
                                PersonalCategoryEvaluationScreen(store: store, learning: learning, attemptID: attempt.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section {
                Button("Reset personalised suggestions", role: .destructive) {
                    clearScope = learning.accountScope
                    clearing = true
                }
            } footer: {
                Text("Keeps your transactions and saved category choices.")
            }
        }
        .navigationTitle("Advanced learning details")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Reset personalised suggestions?", isPresented: $clearing) {
            Button("Reset suggestions", role: .destructive) {
                if clearScope == learning.accountScope { learning.clearAll() }
                clearScope = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Training will stop. Your transactions and their categories stay saved.") }
        .onChange(of: learning.accountScope) { _, _ in
            clearing = false
            clearScope = nil
            showingTechnicalDetails = false
        }
    }
}
