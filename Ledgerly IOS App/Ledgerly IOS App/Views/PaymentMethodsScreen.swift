import SwiftUI

struct PaymentMethodsScreen: View {
    @ObservedObject var store: LedgerStore
    @State private var showingAdd = false
    @State private var name = ""
    @State private var kind: PaymentKind = .cash
    @State private var lastFour = ""
    @State private var editingMethod: LedgerPaymentMethod?

    var body: some View {
        List {
            Section("Active") {
                ForEach(store.activePaymentMethods) { method in
                    Button {
                        editingMethod = method
                        name = method.name
                        kind = method.kind
                        lastFour = method.lastFour ?? ""
                        showingAdd = true
                    } label: {
                        methodRow(method)
                    }
                    .swipeActions {
                        Button("Archive") { store.archivePaymentMethod(method) }.tint(.orange)
                    }
                }
            }
            if store.paymentMethods.contains(where: \.isArchived) {
                Section("Archived") {
                    ForEach(store.paymentMethods.filter(\.isArchived)) { method in
                        HStack {
                            methodRow(method).foregroundStyle(.secondary)
                            Spacer()
                            Button("Restore") { store.restorePaymentMethod(method) }
                        }
                    }
                }
            }
            Section {
                Text("Only a card's optional last four digits are stored. Ledgerly never asks for a full card number, expiry date, or CVV.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Payment methods")
        .toolbar {
            Button { editingMethod = nil; name = ""; kind = .cash; lastFour = ""; showingAdd = true } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add payment method")
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                Form {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $kind) {
                        ForEach(PaymentKind.allCases) { Text($0.label).tag($0) }
                    }
                    if kind == .debitCard || kind == .creditCard {
                        TextField("Last four digits (optional)", text: $lastFour)
                            .keyboardType(.numberPad)
                    }
                }
                .navigationTitle(editingMethod == nil ? "New payment method" : "Edit payment method")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingAdd = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let finalLastFour = (kind == .debitCard || kind == .creditCard) && !lastFour.isEmpty ? lastFour : nil
                            let saved: Bool
                            if let editingMethod {
                                saved = store.updatePaymentMethod(editingMethod, name: name, kind: kind, lastFour: finalLastFour)
                            } else {
                                saved = store.savePaymentMethod(name: name, kind: kind, lastFour: finalLastFour)
                            }
                            if saved { showingAdd = false }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func methodRow(_ method: LedgerPaymentMethod) -> some View {
        VStack(alignment: .leading) {
            Text(method.name)
            Text(method.lastFour.map { "\(method.kind.label) · •••• \($0)" } ?? method.kind.label)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
