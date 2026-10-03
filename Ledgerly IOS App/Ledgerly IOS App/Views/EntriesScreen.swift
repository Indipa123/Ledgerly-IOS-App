import SwiftUI

struct EntriesScreen: View {
    @ObservedObject var store: LedgerStore
    let add: () -> Void
    @State private var search = ""
    @State private var query = TransactionQuery()
    @State private var kindSelection = 0
    @State private var showingFilters = false
    private var filtered: [LedgerEntry] {
        var request = query
        request.kind = kindSelection == 0 ? nil : kindSelection == 1 ? .expense : .income
        request.search = search
        return request.apply(to: store.entries, asOf: .now)
    }
    var body: some View {
        List {
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
                    NavigationLink { EntryDetail(store: store, entry: entry) } label: {
                        EntryRow(entry: entry)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { store.delete(entry) }
                    }
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Transactions")
        .sheet(isPresented: $showingFilters) {
            TransactionFiltersScreen(store: store, query: $query)
        }
        .toolbar {
            Button(action: add) { Image(systemName: "plus") }.accessibilityLabel("Add transaction")
        }
    }
}
