import SwiftUI

struct CategoryBudgetRow: View {
    let limit: CategoryBudget
    let entries: [LedgerEntry]

    private var spent: Decimal {
        guard let month = Calendar.current.dateInterval(of: .month, for: .now) else { return 0 }
        return limit.spent(in: entries, month: month, asOf: .now)
    }

    var body: some View {
        HStack(spacing: 12) {
            LedgerIconTile(icon: .category(limit.categoryName, kind: .expense), size: 38)
            VStack(alignment: .leading, spacing: 5) {
                Text(limit.categoryName).font(.subheadline.bold())
                Text("\(LKR.string(spent)) of \(LKR.string(limit.amount))")
                    .font(.footnote).foregroundStyle(.secondary)
                ProgressView(value: min(1, NSDecimalNumber(decimal: spent / limit.amount).doubleValue))
                    .tint(spent >= limit.amount ? Palette.coral : Palette.cranberry)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct CategoryBudgetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    let initialCategoryID: UUID?
    @State private var categoryID: UUID?
    @State private var amount = ""
    @State private var showingRemoveConfirmation = false

    private var categories: [LedgerCategory] { store.activeCategories(for: .expense) }
    private var category: LedgerCategory? { categories.first { $0.id == categoryID } }
    private var currentLimit: CategoryBudget? {
        guard let category else { return nil }
        let key = CategoryBudget.key(monthKey: CategoryBudget.monthKey(for: .now),
                                     categoryName: category.name)
        return store.categoryBudgets.first { $0.id == key }
    }
    private var parsedAmount: Decimal? {
        let cleaned = amount.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: cleaned), value > 0 else { return nil }
        return value
    }

    var body: some View {
        Form {
            Section("Expense category") {
                Picker("Category", selection: $categoryID) {
                    ForEach(categories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
            }
            Section("Monthly limit") {
                TextField("Amount in LKR", text: $amount)
                    .keyboardType(.decimalPad)
                    .accessibilityLabel("Category spending limit in rupees")
                if let currentLimit {
                    LabeledContent("Current limit", value: LKR.string(currentLimit.amount))
                }
                Text("The limit applies to this month only. It tracks your expenses in this category through today.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let currentLimit,
               let month = Calendar.current.dateInterval(of: .month, for: .now) {
                let spent = currentLimit.spent(in: store.entries, month: month, asOf: .now)
                Section("Progress") {
                    LabeledContent("Spent", value: LKR.string(spent))
                    LabeledContent(spent > currentLimit.amount ? "Over limit" : "Remaining",
                                   value: LKR.string(abs(currentLimit.amount - spent)))
                }
                Section {
                    Button("Remove category limit", role: .destructive) {
                        showingRemoveConfirmation = true
                    }
                }
            }
        }
        .navigationTitle(currentLimit == nil ? "Add category limit" : "Edit category limit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(category == nil || parsedAmount == nil || parsedAmount == currentLimit?.amount)
            }
        }
        .onAppear {
            if let initialCategoryID, categories.contains(where: { $0.id == initialCategoryID }) {
                categoryID = initialCategoryID
            } else {
                categoryID = categories.first { candidate in
                    let key = CategoryBudget.key(monthKey: CategoryBudget.monthKey(for: .now),
                                                 categoryName: candidate.name)
                    return !store.categoryBudgets.contains { $0.id == key }
                }?.id ?? categories.first?.id
            }
            loadAmount()
        }
        .onChange(of: categoryID) { _, _ in loadAmount() }
        .confirmationDialog("Remove this category limit?", isPresented: $showingRemoveConfirmation) {
            Button("Remove limit", role: .destructive) {
                if let category, store.setCategoryBudget(for: category, amount: 0) { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Transactions and the overall monthly budget will stay saved.")
        }
    }

    private func loadAmount() {
        amount = currentLimit.map { NSDecimalNumber(decimal: $0.amount).stringValue } ?? ""
    }

    private func save() {
        guard let category, let parsedAmount else { return }
        if store.setCategoryBudget(for: category, amount: parsedAmount) { dismiss() }
    }
}
