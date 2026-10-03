import SwiftUI

struct EntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    let initialKind: EntryKind
    var editing: LedgerEntry? = nil
    @State private var kind = EntryKind.expense
    @State private var amount = ""
    @State private var title = ""
    @State private var categoryID: UUID?
    @State private var paymentMethodID: UUID?
    @State private var date = Date()
    @State private var note = ""
    @State private var discard = false
    private var value: Decimal? {
        guard let parsed = Decimal(string: amount.replacingOccurrences(of: ",", with: ".")), parsed > 0 else { return nil }
        return parsed
    }
    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) {
                    ForEach(EntryKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Amount in LKR", text: $amount).keyboardType(.decimalPad)
                TextField(kind == .expense ? "Merchant or description (optional)" : "Source or description (optional)", text: $title)
                Picker("Category", selection: $categoryID) {
                    Text("Choose a category").tag(Optional<UUID>.none)
                    ForEach(store.activeCategories(for: kind)) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                Picker("Payment method", selection: $paymentMethodID) {
                    Text("Not specified").tag(Optional<UUID>.none)
                    ForEach(store.activePaymentMethods) { method in
                        Text(method.name).tag(Optional(method.id))
                    }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Note (optional)", text: $note, axis: .vertical).lineLimit(2...4)
            }
            .navigationTitle(editing == nil ? "New transaction" : "Edit transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { discard = true } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { Image(systemName: "checkmark") }
                        .disabled(value == nil || categoryID == nil)
                        .accessibilityLabel("Save transaction")
                }
            }
            .onAppear {
                if let editing {
                    kind = editing.kind
                    amount = NSDecimalNumber(decimal: editing.amount).stringValue
                    title = editing.title
                    categoryID = editing.categoryID ?? store.activeCategories(for: editing.kind).first { $0.name == editing.category }?.id
                    paymentMethodID = editing.paymentMethodID
                    date = editing.date
                    note = editing.note
                } else {
                    kind = initialKind
                    categoryID = store.activeCategories(for: initialKind).first?.id
                }
            }
            .onChange(of: kind) { _, selected in
                if !store.activeCategories(for: selected).contains(where: { $0.id == categoryID }) {
                    categoryID = store.activeCategories(for: selected).first?.id
                }
            }
            .confirmationDialog("Discard changes?", isPresented: $discard) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
    }
    private func save() {
        guard let value, let categoryID,
              let category = store.activeCategories(for: kind).first(where: { $0.id == categoryID }) else { return }
        let item = LedgerEntry(id: editing?.id ?? UUID(), kind: kind, amount: value,
                               title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                               category: category.name, date: date, note: note,
                               categoryID: categoryID, paymentMethodID: paymentMethodID)
        if store.save(item) { dismiss() }
    }
}
