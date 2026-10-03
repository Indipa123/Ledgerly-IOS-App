import SwiftUI

struct CategoriesScreen: View {
    @ObservedObject var store: LedgerStore
    @State private var kind: EntryKind = .expense
    @State private var showingAdd = false
    @State private var newName = ""
    @State private var editingCategory: LedgerCategory?

    private var categories: [LedgerCategory] { store.categories.filter { $0.kind == kind } }

    var body: some View {
        List {
            Picker("Type", selection: $kind) {
                ForEach(EntryKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Section("Active") {
                ForEach(categories.filter { !$0.isArchived }) { category in
                    Button {
                        editingCategory = category
                    } label: {
                        HStack {
                            Text(category.name)
                            Spacer()
                            if category.isSystem { Text("Built in").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .swipeActions {
                        Button("Archive") { store.archiveCategory(category) }.tint(.orange)
                    }
                }
            }
            if categories.contains(where: \.isArchived) {
                Section("Archived") {
                    ForEach(categories.filter(\.isArchived)) { category in
                        HStack {
                            Text(category.name).foregroundStyle(.secondary)
                            Spacer()
                            Button("Restore") { store.restoreCategory(category) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Categories")
        .toolbar {
            Button { newName = ""; showingAdd = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add category")
        }
        .alert("New \(kind.label.lowercased()) category", isPresented: $showingAdd) {
            TextField("Name", text: $newName)
            Button("Add") { store.saveCategory(name: newName, kind: kind) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Categories keep your spending and income organised.")
        }
        .sheet(item: $editingCategory) { category in
            CategoryNameEditor(store: store, category: category)
        }
    }
}

private struct CategoryNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    let category: LedgerCategory
    @State private var name: String

    init(store: LedgerStore, category: LedgerCategory) {
        self.store = store
        self.category = category
        _name = State(initialValue: category.name)
    }

    var body: some View {
        NavigationStack {
            Form { TextField("Name", text: $name) }
                .navigationTitle("Edit category")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if store.renameCategory(category, to: name) { dismiss() }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
