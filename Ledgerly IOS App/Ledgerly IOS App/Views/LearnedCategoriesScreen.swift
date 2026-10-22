import SwiftUI

struct LearnedCategoriesScreen: View {
    private enum ForgetTarget {
        case group(CategoryLearningGroup)
        case all
    }

    @ObservedObject var store: LedgerStore
    @State private var forgetTarget: ForgetTarget?
    @State private var search = ""
    @State private var mixedOnly = false

    private var groups: [CategoryLearningGroup] { store.learnedCategoryGroups }
    private var visibleGroups: [CategoryLearningGroup] {
        CategoryLearningReview.groups(groups, search: search, mixedOnly: mixedOnly)
    }

    var body: some View {
        List {
            Section {
                Text("Ledgerly learns from the categories you choose. Review or forget saved choices here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    CategoryReviewScreen(store: store)
                } label: {
                    LabeledContent {
                        Text("\(store.categoryReviewEntries.count)")
                    } label: {
                        Label("Categories to review", systemImage: "checklist")
                    }
                }
                NavigationLink {
                    PersonalCategoryModelsScreen(store: store, learning: store.personalLearning)
                } label: {
                    Label("Personalise suggestions", systemImage: "brain")
                }
                NavigationLink {
                    ExcludedCategoryExamplesScreen(store: store)
                } label: {
                    LabeledContent {
                        Text("\(store.excludedCategoryExamples.count)")
                    } label: {
                        Label("Excluded examples", systemImage: "arrow.uturn.backward.circle")
                    }
                }
            }

            if !groups.isEmpty {
                Section("Review saved choices") {
                    LabeledContent("Descriptions with different categories",
                                   value: "\(groups.filter(\.hasMixedCategories).count)")
                    Toggle("Show different categories only", isOn: $mixedOnly)
                    Text("Open a description to review its transactions or change what Ledgerly learns from it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Saved examples") {
                    if visibleGroups.isEmpty {
                        ContentUnavailableView("No matching descriptions", systemImage: "magnifyingglass",
                            description: Text("Change your search or turn off the filter to see other saved examples."))
                    }
                    ForEach(visibleGroups) { group in
                        NavigationLink {
                            CategoryLearningDetailScreen(store: store, groupID: group.id)
                        } label: {
                            HStack(spacing: 12) {
                                LedgerIconTile(icon: .init(symbol: group.hasMixedCategories
                                    ? "rectangle.2.swap" : "sparkle.magnifyingglass", color: Palette.iconPlum), size: 40)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.title).font(.body.weight(.medium))
                                    Text(categorySummary(for: group))
                                        .font(.footnote).foregroundStyle(.secondary)
                                    Text("\(group.exampleCount) saved \(group.exampleCount == 1 ? "example" : "examples") · \(group.kind.label)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if group.hasMixedCategories {
                                        Label("Different categories", systemImage: "rectangle.2.swap")
                                            .font(.caption.weight(.medium)).foregroundStyle(Palette.iconPlum)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .swipeActions {
                            Button("Forget", role: .destructive) { forgetTarget = .group(group) }
                        }
                    }
                }
            }

            Section {
                DisclosureGroup("Advanced") {
                    NavigationLink("Suggestion checks") {
                        CategoryLearningChecksScreen(store: store)
                    }
                }
            }

            if groups.isEmpty {
                ContentUnavailableView("Nothing learned yet", systemImage: "sparkle.magnifyingglass",
                                       description: Text("Save a transaction with a description and category to start learning."))
            } else {
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
        .searchable(text: $search, prompt: "Search learned descriptions")
        .onChange(of: store.categoryLearningScope) { _, _ in
            search = ""
            mixedOnly = false
            forgetTarget = nil
        }
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
            }
            Button("Cancel", role: .cancel) { forgetTarget = nil }
        } message: {
            Text("Transactions and categories stay saved. Ledgerly stops using these examples for future suggestions on this device.")
        }
    }

    private func categorySummary(for group: CategoryLearningGroup) -> String {
        group.categoryCounts.sorted {
            $0.value == $1.value ? $0.key.uuidString < $1.key.uuidString : $0.value > $1.value
        }.map { id, count in
            let name = store.categories.first(where: { $0.id == id })?.name ?? "Previous category"
            return "\(name) \(count)"
        }.joined(separator: " · ")
    }

}

/// Optional checks remain available for evaluation without filling the main learning screen.
private struct CategoryLearningChecksScreen: View {
    @ObservedObject var store: LedgerStore
    @State private var qualityReport: CategoryEvaluationReport?

    var body: some View {
        List {
            Section("Saved-choice matcher quality") {
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
                    Text("Retrospective check of saved-choice matching only; it does not measure the bundled model. The oldest \(report.trainingCount) saved examples train the matcher; the newest \(report.testCount) test it. Accuracy applies only when a suggestion was made. Small samples can change quickly.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Save at least 10 categorised transactions with descriptions to see a time-ordered accuracy check.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Bundled model test") {
                LabeledContent("Known descriptions", value: "7 correct of 7 suggested")
                LabeledContent("Known descriptions covered", value: "7 of 16")
                LabeledContent("Vague descriptions", value: "0 suggested of 8")
                Text("These hand-written test descriptions were separate from model training and threshold selection. The conservative gate leaves uncertain descriptions for you to categorise. This small test does not predict accuracy for every merchant or receipt.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        }
        .navigationTitle("Suggestion checks")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(store.$categoryMemory) { _ in qualityReport = store.evaluateCategoryLearning() }
        .onChange(of: store.categoryLearningScope) { _, _ in qualityReport = store.evaluateCategoryLearning() }
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}
