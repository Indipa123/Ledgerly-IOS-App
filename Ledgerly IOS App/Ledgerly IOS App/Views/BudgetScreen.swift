import SwiftUI

struct BudgetScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    @State private var amount = ""
    @State private var showingRemoveConfirmation = false

    private var parsedAmount: Decimal? {
        let cleaned = amount.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: cleaned), value > 0 else { return nil }
        return value
    }

    var body: some View {
        Form {
            Section("Monthly budget") {
                TextField("Amount in LKR", text: $amount)
                    .keyboardType(.decimalPad)
                    .accessibilityLabel("Monthly budget amount in rupees")
                if store.budget > 0 {
                    LabeledContent("Current budget", value: LKR.string(store.budget))
                }
                Text("Choose how much you plan to spend this month. Editing the budget does not change your transactions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("This month's progress") {
                LabeledContent("Spent", value: LKR.string(store.spentSoFar))
                if store.budget > 0 {
                    let remaining = store.budget - store.spentSoFar
                    LabeledContent(remaining < 0 ? "Over budget" : "Remaining",
                                   value: LKR.string(abs(remaining)))
                }
            }
            if store.budget > 0 {
                Section {
                    Button("Remove monthly budget", role: .destructive) {
                        showingRemoveConfirmation = true
                    }
                }
            }
        }
        .navigationTitle(store.budget > 0 ? "Edit budget" : "Set budget")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(parsedAmount == nil || parsedAmount == store.budget)
            }
        }
        .onAppear {
            amount = store.budget > 0 ? NSDecimalNumber(decimal: store.budget).stringValue : ""
        }
        .confirmationDialog("Remove this month's budget?", isPresented: $showingRemoveConfirmation) {
            Button("Remove budget", role: .destructive) {
                if store.setBudget(0) {
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your transactions will stay saved. You can set a new budget any time.")
        }
    }

    private func save() {
        guard let parsedAmount else { return }
        if store.setBudget(parsedAmount) {
            dismiss()
        }
    }
}
