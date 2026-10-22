import SwiftUI

struct ExcludedCategoryExamplesScreen: View {
    @ObservedObject var store: LedgerStore
    @State private var scope: UUID
    @State private var search = ""
    @State private var kind: EntryKind?
    @State private var restoringIDs: Set<UUID> = []

    init(store: LedgerStore) {
        self.store = store
        _scope = State(initialValue: store.categoryLearningScope)
    }

    private var visible: [LedgerEntry] {
        guard scope == store.categoryLearningScope else { return [] }
        let excluded = store.excludedCategoryExamples
        return CategoryLearningReview.excludedExamples(entries: excluded,
            excludedEntryIDs: Set(excluded.map(\.id)), search: search, kind: kind)
    }

    var body: some View {
        Group {
            if scope != store.categoryLearningScope {
                ContentUnavailableView("Account changed", systemImage: "person.crop.circle",
                    description: Text("Return to Learned categories to manage this account's examples."))
            } else {
                List {
                    Section {
                        Text("These transactions were excluded from category learning. Restore an example to let Ledgerly use its saved category again. Your transactions and amounts stay the same.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Picker("Type", selection: $kind) {
                            Text("All").tag(Optional<EntryKind>.none)
                            ForEach(EntryKind.allCases) { Text($0.label).tag(Optional($0)) }
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text("Restored transactions can guide suggestions again. Personalised suggestions update according to your learning settings.")
                    }
                    if visible.isEmpty {
                        ContentUnavailableView(search.isEmpty && kind == nil
                            ? "No excluded examples" : "No matching examples",
                            systemImage: "checkmark.circle",
                            description: Text("Examples you forget can be restored here while their transactions remain in your ledger."))
                    } else {
                        Section {
                            Button("Restore visible examples (\(visible.count))", systemImage: "arrow.uturn.backward") {
                                restoringIDs = Set(visible.map(\.id))
                            }
                        }
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
                            Button("Use for suggestions", systemImage: "arrow.uturn.backward.circle") {
                                store.restoreCategoryLearning(for: [entry.id], scope: scope)
                            }
                            .accessibilityLabel("Use \(entry.displayTitle), \(entry.category), for category suggestions")
                        }
                    }
                }
            }
        }
        .navigationTitle("Excluded examples")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search description or category")
        .confirmationDialog("Restore \(restoringIDs.count) examples for learning?", isPresented: Binding(
            get: { !restoringIDs.isEmpty }, set: { if !$0 { restoringIDs = [] } })) {
                Button("Restore examples") {
                    store.restoreCategoryLearning(for: restoringIDs, scope: scope)
                    restoringIDs = []
                }
                Button("Cancel", role: .cancel) { restoringIDs = [] }
            } message: {
                Text("Only the examples visible when you tapped Restore will be included. This changes learning preferences for this account on this device; financial records stay unchanged.")
            }
        .onChange(of: store.categoryLearningScope) { _, _ in restoringIDs = [] }
    }
}
