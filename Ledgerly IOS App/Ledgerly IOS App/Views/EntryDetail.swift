import SwiftUI

struct EntryDetail: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    let entry: LedgerEntry
    @State private var editing = false
    @State private var deleting = false
    var body: some View {
        Form {
            Section {
                LabeledContent("Amount", value: LKR.string(entry.amount))
                LabeledContent("Type", value: entry.kind.label)
                LabeledContent("Category", value: entry.category)
                if let method = store.paymentMethods.first(where: { $0.id == entry.paymentMethodID }) {
                    LabeledContent("Payment method", value: method.name)
                }
                LabeledContent("Date", value: entry.date.formatted(date: .long, time: .omitted))
                if !entry.note.isEmpty { LabeledContent("Note", value: entry.note) }
            }
            Button("Delete transaction", role: .destructive) { deleting = true }
        }
        .navigationTitle(entry.displayTitle)
        .toolbar { Button("Edit") { editing = true } }
        .sheet(isPresented: $editing) { EntryEditor(store: store, initialKind: entry.kind, editing: entry) }
        .confirmationDialog("Delete this transaction?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { store.delete(entry); dismiss() }
        }
    }
}
