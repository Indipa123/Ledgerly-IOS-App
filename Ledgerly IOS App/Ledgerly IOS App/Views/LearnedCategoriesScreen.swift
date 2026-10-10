import SwiftUI

struct LearnedCategoriesScreen: View {
    private enum ForgetTarget {
        case group(CategoryLearningGroup)
        case all
    }

    @ObservedObject var store: LedgerStore
    @State private var forgetTarget: ForgetTarget?
    @State private var qualityReport: CategoryEvaluationReport?

    var body: some View {
        List {
            Section {
                Text("Ledgerly calculates suggestions on this device from the categories you save with a merchant or source. Similar descriptions may get a suggestion; uncertain matches still ask you to choose.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Suggestion quality") {
                if let report = qualityReport {
                    LabeledContent("Checked newer transactions", value: "\(report.testCount)")
                    LabeledContent("Suggestions made",
                                   value: "\(report.suggestedCount) of \(report.testCount) (\(percent(report.coverage)))")
                    LabeledContent("Correct when suggested",
                                   value: report.accuracyWhenSuggested.map(percent) ?? "No suggestions yet")
                    LabeledContent("Most common category", value: percent(report.majorityBaselineAccuracy))
                    LabeledContent("Exact name lookup",
                                   value: report.exactBaselineAccuracy.map {
                                       "\(percent($0)) at \(percent(report.exactBaselineCoverage)) coverage"
                                   } ?? "No matches")
                    if report.unseenDescriptionCount > 0 {
                        LabeledContent("New descriptions",
                                       value: "\(report.unseenCorrectCount) correct of \(report.unseenSuggestedCount) suggested; \(report.unseenDescriptionCount) checked")
                    }
                    Text("Retrospective check: the oldest \(report.trainingCount) saved examples train the matcher; the newest \(report.testCount) test it. Accuracy applies only when a suggestion was made. Small samples can change quickly.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Save at least 10 categorised transactions with descriptions to see a time-ordered accuracy check.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if store.learnedCategoryGroups.isEmpty {
                ContentUnavailableView("Nothing learned yet", systemImage: "sparkle.magnifyingglass",
                                       description: Text("Save a transaction with a description and category to start learning."))
            } else {
                Section("Saved examples") {
                    ForEach(store.learnedCategoryGroups) { group in
                        HStack(spacing: 12) {
                            LedgerIconTile(icon: .init(symbol: "sparkle.magnifyingglass",
                                                       color: Palette.iconPlum), size: 40)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.title).font(.body.weight(.medium))
                                Text(categorySummary(for: group))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Text("\(group.exampleCount) saved \(group.exampleCount == 1 ? "example" : "examples") · \(group.kind.label)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button("Forget") { forgetTarget = .group(group) }
                                .font(.footnote)
                                .accessibilityLabel("Forget category learning for \(group.title)")
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section {
                    Button("Forget all learned categories", role: .destructive) {
                        forgetTarget = .all
                    }
                } footer: {
                    Text("Forgetting a suggestion keeps your transactions and their categories. New transactions can teach Ledgerly again.")
                }
            }
        }
        .navigationTitle("Learned categories")
        .onAppear { qualityReport = store.evaluateCategoryLearning() }
        .alert("Forget category learning?", isPresented: Binding(
            get: { forgetTarget != nil },
            set: { if !$0 { forgetTarget = nil } }
        )) {
            Button("Forget", role: .destructive) {
                switch forgetTarget {
                case .group(let group): store.forgetCategoryLearning(for: group)
                case .all: store.forgetAllCategoryLearning()
                case .none: break
                }
                forgetTarget = nil
                qualityReport = store.evaluateCategoryLearning()
            }
            Button("Cancel", role: .cancel) { forgetTarget = nil }
        } message: {
            Text("Transactions and categories stay saved. Ledgerly stops using these examples for future suggestions on this device.")
        }
    }

    private func categorySummary(for group: CategoryLearningGroup) -> String {
        group.categoryCounts.sorted { $0.value > $1.value }.map { id, count in
            let name = store.categories.first(where: { $0.id == id })?.name ?? "Previous category"
            return "\(name) \(count)"
        }.joined(separator: " · ")
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}
