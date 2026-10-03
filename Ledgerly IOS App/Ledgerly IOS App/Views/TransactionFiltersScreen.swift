import SwiftUI

struct TransactionFiltersScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    @Binding var query: TransactionQuery
    @State private var minimumAmount = ""
    @State private var maximumAmount = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    Picker("Period", selection: $query.period) {
                        ForEach(TransactionPeriod.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .onChange(of: query.period) { _, selected in
                        if selected == .custom {
                            query.startDate = query.startDate ?? .now
                            query.endDate = query.endDate ?? .now
                        }
                    }
                    if query.period == .custom {
                        DatePicker("From", selection: Binding(
                            get: { query.startDate ?? .now },
                            set: { query.startDate = $0 }
                        ), displayedComponents: .date)
                        DatePicker("To", selection: Binding(
                            get: { query.endDate ?? .now },
                            set: { query.endDate = $0 }
                        ), displayedComponents: .date)
                        if let start = query.startDate, let end = query.endDate, start > end {
                            Text("The end date must be on or after the start date.")
                                .font(.footnote).foregroundStyle(.red)
                        }
                    }
                }
                Section("Category") {
                    Picker("Category", selection: $query.categoryID) {
                        Text("All categories").tag(Optional<UUID>.none)
                        ForEach(store.categories.filter { !$0.isArchived || $0.id == query.categoryID }) { category in
                            Text("\(category.name) (\(category.kind.label))").tag(Optional(category.id))
                        }
                    }
                }
                Section("Payment method") {
                    Picker("Method", selection: $query.paymentMethodID) {
                        Text("All methods").tag(Optional<UUID>.none)
                        ForEach(store.paymentMethods.filter { !$0.isArchived || $0.id == query.paymentMethodID }) { method in
                            Text(method.name).tag(Optional(method.id))
                        }
                    }
                }
                Section("Amount") {
                    TextField("Minimum in LKR", text: $minimumAmount)
                        .keyboardType(.decimalPad)
                    TextField("Maximum in LKR", text: $maximumAmount)
                        .keyboardType(.decimalPad)
                    if let min = query.minimumAmount, let max = query.maximumAmount, min > max {
                        Text("The maximum must be at least the minimum.")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
                Section("Order") {
                    Picker("Sort by", selection: $query.sort) {
                        ForEach(TransactionSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section {
                    Button("Clear filters") {
                        query = TransactionQuery()
                        minimumAmount = ""
                        maximumAmount = ""
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                minimumAmount = query.minimumAmount.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
                maximumAmount = query.maximumAmount.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
            }
            .onChange(of: minimumAmount) { _, value in
                query.minimumAmount = Decimal(string: value.replacingOccurrences(of: ",", with: "."))
            }
            .onChange(of: maximumAmount) { _, value in
                query.maximumAmount = Decimal(string: value.replacingOccurrences(of: ",", with: "."))
            }
        }
    }
}
