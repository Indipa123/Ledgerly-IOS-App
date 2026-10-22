import SwiftUI

struct CategoryLearningDetailScreen: View {
    @ObservedObject var store: LedgerStore
    let groupID: String
    @State private var scope: UUID
    @State private var excluding: LedgerEntry?
    @State private var forgettingGroup = false

    init(store: LedgerStore, groupID: String) {
        self.store = store
        self.groupID = groupID
        _scope = State(initialValue: store.categoryLearningScope)
    }

    private var group: CategoryLearningGroup? {
        guard scope == store.categoryLearningScope else { return nil }
        return store.learnedCategoryGroups.first { $0.id == groupID }
    }

    var body: some View {
        Group {
            if let group {
                examplesList(group)
            } else {
                ContentUnavailableView("Examples unavailable", systemImage: "sparkle.magnifyingglass",
                    description: Text("Return to Learned categories to see your current saved choices."))
            }
        }
        .navigationTitle(group?.title ?? "Saved choices")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Exclude this example from learning?", isPresented: Binding(
            get: { excluding != nil }, set: { if !$0 { excluding = nil } })) {
                Button("Exclude example", role: .destructive) {
                    if scope == store.categoryLearningScope, let id = excluding?.id,
                       group?.entryIDs.contains(id) == true {
                        store.forgetCategoryLearning(for: id)
                    }
                    excluding = nil
                }
                Button("Cancel", role: .cancel) { excluding = nil }
            } message: {
                Text("The transaction and its category stay saved. This example stops contributing to category suggestions on this device.")
            }
        .confirmationDialog("Forget all examples for this description?", isPresented: $forgettingGroup) {
            Button("Forget examples", role: .destructive) {
                if let group { store.forgetCategoryLearning(for: group) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Transactions keep their categories. New transactions can teach this description again.")
        }
        .onChange(of: store.categoryLearningScope) { _, _ in
            excluding = nil
            forgettingGroup = false
        }
    }

    private func examplesList(_ group: CategoryLearningGroup) -> some View {
        List {
            Section {
                Label(group.hasMixedCategories ? "Saved under different categories" : "Saved choices agree",
                      systemImage: group.hasMixedCategories ? "rectangle.2.swap" : "checkmark.circle")
                    .font(.headline)
                Text(group.hasMixedCategories
                    ? "You have used different categories for this description. Review transactions before changing them."
                    : "Review the transactions that guide this suggestion.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Saved categories") {
                ForEach(group.categoryCounts.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                    let category = store.categories.first { $0.id == id }
                    LabeledContent(category.map { $0.name + ($0.isArchived ? " (archived)" : "") }
                                   ?? "Previous category", value: "\(group.categoryCounts[id, default: 0])")
                }
            }
            Section {
                ForEach(CategoryLearningReview.examples(in: group, entries: store.entries)) { entry in
                    NavigationLink {
                        if scope == store.categoryLearningScope {
                            EntryDetail(store: store, entry: entry)
                        } else {
                            ContentUnavailableView("Account changed", systemImage: "person.crop.circle",
                                description: Text("Return to Learned categories to review this account's examples."))
                        }
                    } label: { EntryRow(entry: entry) }
                        .swipeActions {
                            Button("Exclude from learning", role: .destructive) { excluding = entry }
                        }
                        .contextMenu {
                            Button("Exclude from learning", systemImage: "minus.circle") { excluding = entry }
                        }
                }
            } header: {
                Text("Transactions · \(group.exampleCount)")
            } footer: {
                Text("Open a transaction to edit its category. Excluding it from learning keeps it in your ledger.")
            }
            Section {
                Button("Forget this description's examples", role: .destructive) { forgettingGroup = true }
            }
        }
    }
}
