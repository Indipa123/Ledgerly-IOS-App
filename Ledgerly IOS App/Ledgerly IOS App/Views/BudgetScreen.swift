import SwiftUI

struct BudgetScreen: View {
    @ObservedObject var store: LedgerStore
    @State private var amount = ""
    @State private var editing = false
    var body: some View {
        Form {
            Section("This month") {
                LabeledContent("Budget", value: LKR.string(store.budget))
                LabeledContent("Spent", value: LKR.string(store.spentSoFar))
                LabeledContent("Remaining", value: LKR.string(store.budget - store.spentSoFar))
            }
            Button(store.budget > 0 ? "Change budget" : "Set monthly budget") {
                amount = store.budget > 0 ? NSDecimalNumber(decimal: store.budget).stringValue : ""
                editing = true
            }
        }
        .navigationTitle("Budget")
        .alert("Monthly budget", isPresented: $editing) {
            TextField("Amount in LKR", text: $amount).keyboardType(.decimalPad)
            Button("Save") {
                if let value = Decimal(string: amount.replacingOccurrences(of: ",", with: ".")), value >= 0 {
                    store.setBudget(value)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Set what you plan to spend this month.") }
    }
}
