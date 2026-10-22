import SwiftUI

struct CategoryReviewScreen: View {
    @ObservedObject var store: LedgerStore
    @State private var scope: UUID
    @State private var search = ""
    @State private var kind: EntryKind?
    @State private var showingReviewed = false

    init(store: LedgerStore) {
        self.store = store
        _scope = State(initialValue: store.categoryLearningScope)
    }

    private var visible: [LedgerEntry] {
        guard scope == store.categoryLearningScope else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = showingReviewed ? store.reviewedCategoryEntries : store.categoryReviewEntries
        return entries.filter { entry in
            (kind == nil || entry.kind == kind) &&
            (query.isEmpty || entry.title.localizedStandardContains(query) ||
             entry.category.localizedStandardContains(query))
        }
    }

    var body: some View {
        Group {
            if scope != store.categoryLearningScope {
                ContentUnavailableView("Account changed", systemImage: "person.crop.circle",
                    description: Text("Return to Learned categories to review this account's transactions."))
            } else {
                List {
                    Section {
                        Text("Check these categories and mark them reviewed when they look right.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Picker("Review status", selection: $showingReviewed) {
                            Text("To review").tag(false)
                            Text("Reviewed").tag(true)
                        }
                        .pickerStyle(.segmented)
                        Picker("Type", selection: $kind) {
                            Text("All").tag(Optional<EntryKind>.none)
                            ForEach(EntryKind.allCases) { Text($0.label).tag(Optional($0)) }
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text("Shows transactions saved for review on this device.")
                    }
                    if visible.isEmpty {
                        ContentUnavailableView(search.isEmpty && kind == nil
                            ? (showingReviewed ? "No reviewed categories" : "Nothing to review")
                            : "No matching transactions", systemImage: "checkmark.circle",
                            description: Text("No recorded transactions match this review list."))
                    }
                    ForEach(visible) { entry in
                        Section {
                            NavigationLink {
                                if scope == store.categoryLearningScope {
                                    EntryDetail(store: store, entry: entry)
                                } else {
                                    ContentUnavailableView("Account changed", systemImage: "person.crop.circle")
                                }
                            } label: { EntryRow(entry: entry) }
                            if showingReviewed, let review = entry.categorySuggestion?.review {
                                LabeledContent("Reviewed", value: review.reviewedAt.formatted(
                                    date: .abbreviated, time: .shortened))
                            }
                            Button(showingReviewed ? "Review again" : "Mark category reviewed",
                                   systemImage: showingReviewed ? "arrow.uturn.backward.circle" : "checkmark.circle") {
                                if showingReviewed { store.reopenCategoryReview(entry, scope: scope) }
                                else { store.markCategoryReviewed(entry, scope: scope) }
                            }
                            .accessibilityLabel(showingReviewed
                                ? "Review \(entry.displayTitle), \(entry.category), again"
                                : "Mark \(entry.displayTitle), \(entry.category), reviewed")
                        }
                    }
                    if !visible.isEmpty {
                        Section {
                            Text(showingReviewed
                                ? "Review again returns the transaction to To review. Reviewed entries are ordered by their latest review time."
                                : "Marking reviewed keeps the transaction and its category. A later change to its description, category or type brings it back for review.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Categories to review")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search description or category")
    }
}
