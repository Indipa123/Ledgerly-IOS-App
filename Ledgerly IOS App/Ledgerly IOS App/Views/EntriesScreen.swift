import SwiftUI

struct EntriesScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var store: LedgerStore
    let add: () -> Void
    var allowsColumns = false
    @State private var search = ""
    @State private var query = TransactionQuery()
    @State private var kindSelection = 0
    @State private var showingFilters = false
    @State private var selectedEntryID: UUID?
    @State private var compactPath: [UUID] = []
    private var filtered: [LedgerEntry] {
        var request = query
        request.kind = kindSelection == 0 ? nil : kindSelection == 1 ? .expense : .income
        request.search = search
        return request.apply(to: store.entries, asOf: .now)
    }

    var body: some View {
        GeometryReader { geometry in
            // Measure the space left by the workspace sidebar, not the device screen.
            // Small windows and accessibility text use the full-width push navigation.
            let usesColumns = allowsColumns &&
                geometry.size.width >= 860 && !dynamicTypeSize.isAccessibilitySize
            Group {
                if usesColumns {
                    HStack(spacing: 0) {
                        NavigationStack {
                            transactionList(usesColumns: true)
                        }
                        .frame(width: min(420, max(340, geometry.size.width * 0.38)))
                        Divider()
                        NavigationStack {
                            if let entry = filtered.first(where: { $0.id == selectedEntryID }) {
                                EntryDetail(store: store, entry: entry)
                                    .id(entry.id)
                                    .navigationBarTitleDisplayMode(.inline)
                            } else {
                                ContentUnavailableView("Select a transaction", systemImage: "list.bullet.rectangle",
                                    description: Text("Choose an expense or income from the list to see its details."))
                                    .navigationTitle("Transaction details")
                                    .navigationBarTitleDisplayMode(.inline)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    NavigationStack(path: $compactPath) {
                        transactionList(usesColumns: false)
                            .navigationDestination(for: UUID.self) { id in
                                if let entry = store.entries.first(where: { $0.id == id }) {
                                    EntryDetail(store: store, entry: entry)
                                } else {
                                    ContentUnavailableView("Transaction unavailable", systemImage: "tray",
                                        description: Text("This transaction is no longer in your ledger."))
                                }
                            }
                    }
                }
            }
            .onChange(of: compactPath) { _, path in selectedEntryID = path.last }
            .onChange(of: filtered.map(\.id)) { _, visibleIDs in
                // Edits, filters, deletion and cloud updates must never leave stale details open.
                if let selectedEntryID, !visibleIDs.contains(selectedEntryID) {
                    self.selectedEntryID = nil
                    compactPath = []
                }
            }
        }
    }

    private func transactionList(usesColumns: Bool) -> some View {
        List(selection: usesColumns ? $selectedEntryID : nil) {
            Picker("Type", selection: $kindSelection) {
                Text("All").tag(0)
                Text("Expenses").tag(1)
                Text("Income").tag(2)
            }
            .pickerStyle(.segmented)
            HStack {
                Text("\(filtered.count) \(filtered.count == 1 ? "transaction" : "transactions")")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingFilters = true
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            if filtered.isEmpty {
                ContentUnavailableView("No transactions", systemImage: "tray", description: Text("Add an entry or change your filters."))
            } else {
                ForEach(filtered) { entry in
                    Button {
                        selectedEntryID = entry.id
                        compactPath = [entry.id]
                    } label: {
                        HStack(spacing: 8) {
                            EntryRow(entry: entry)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !usesColumns {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("transaction-\(entry.id.uuidString)")
                    .accessibilityHint("Open transaction details")
                    .accessibilityAddTraits(usesColumns && selectedEntryID == entry.id ? .isSelected : [])
                    .listRowBackground(usesColumns && selectedEntryID == entry.id ? Palette.cranberry.opacity(0.12) : Palette.card)
                    .tag(entry.id)
                    .swipeActions {
                        Button("Delete", role: .destructive) { store.deleteUndoably(entry) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.cream.ignoresSafeArea())
        .onChange(of: selectedEntryID) { _, id in
            if usesColumns { compactPath = id.map { [$0] } ?? [] }
        }
        .searchable(text: $search, prompt: "Search transactions")
        .navigationTitle("Transactions")
        .navigationBarTitleDisplayMode(usesColumns ? .inline : .large)
        .toolbar(.visible, for: .navigationBar)
        .modifier(TransactionsNavigationBackground())
        .sheet(isPresented: $showingFilters) {
            TransactionFiltersScreen(store: store, query: $query)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink { StatementReconciliationScreen(store: store) } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .accessibilityLabel("Reconcile a statement")
                Button(action: add) { Image(systemName: "plus") }
                    .accessibilityLabel("Add transaction")
            }
        }
    }
}

private struct TransactionsNavigationBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content
                .toolbarBackground(Palette.cream, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
