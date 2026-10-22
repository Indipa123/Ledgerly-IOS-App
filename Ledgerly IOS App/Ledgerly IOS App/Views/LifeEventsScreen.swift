import SwiftUI

struct LifeEventsScreen: View {
    @ObservedObject var store: LedgerStore
    @State private var showingNewEvent = false

    var body: some View {
        List {
            if store.lifeEvents.isEmpty {
                ContentUnavailableView("No event budgets yet", systemImage: "calendar.badge.plus",
                                       description: Text("Plan a trip, celebration, or other life event separately from your monthly budget."))
                Button("Create event budget") { showingNewEvent = true }
            } else {
                ForEach(store.lifeEvents) { event in
                    NavigationLink { LifeEventDetail(store: store, eventID: event.id) } label: {
                        HStack(spacing: 12) {
                            LedgerIconTile(icon: .init(symbol: event.kind.symbol, color: Palette.cranberry), size: 44)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.name).font(.headline)
                                Text(event.completedAt == nil ? event.kind.label : "Completed · \(event.kind.label)")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                ProgressView(value: min(1, max(0, NSDecimalNumber(
                                    decimal: (event.completionSpent ?? event.spent(in: store.entries)) / event.budget
                                ).doubleValue)))
                                    .tint(Palette.cranberry)
                                    .accessibilityLabel("Event budget progress")
                            }
                            Spacer(minLength: 8)
                            Text(LKR.string(event.completionSpent ?? event.spent(in: store.entries)))
                                .font(.subheadline.bold().monospacedDigit())
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
        .navigationTitle("Event budgets")
        .toolbar {
            Button { showingNewEvent = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("Create event budget")
        }
        .sheet(isPresented: $showingNewEvent) {
            NavigationStack { LifeEventEditor(store: store) }
        }
    }
}

private struct LifeEventEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    var editing: LifeEvent? = nil
    @State private var name = ""
    @State private var kind: LifeEventKind = .other
    @State private var budget = ""
    @State private var startDate = Date()
    @State private var endDate = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now

    private var amount: Decimal? {
        guard let value = Decimal(string: budget.replacingOccurrences(of: ",", with: ".")),
              value > 0 else { return nil }
        return value
    }

    var body: some View {
        Form {
            Section("Event") {
                TextField("Name", text: $name)
                Picker("Type", selection: $kind) {
                    ForEach(LifeEventKind.allCases) { type in
                        Label(type.label, systemImage: type.symbol).tag(type)
                    }
                }
                DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                DatePicker("Ends", selection: $endDate, displayedComponents: .date)
            }
            Section("Budget") {
                TextField("Amount in LKR", text: $budget).keyboardType(.decimalPad)
                Text("Expenses linked to this event also appear in your monthly totals. Each transaction is saved once.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if startDate > endDate {
                Text("End date must be on or after the start date.")
                    .font(.footnote).foregroundStyle(.red)
            }
        }
        .navigationTitle(editing == nil ? "New event budget" : "Edit event budget")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              amount == nil || startDate > endDate)
            }
        }
        .onAppear {
            guard let editing else { return }
            name = editing.name
            kind = editing.kind
            budget = NSDecimalNumber(decimal: editing.budget).stringValue
            startDate = editing.startDate
            endDate = editing.endDate
        }
    }

    private func save() {
        guard let amount else { return }
        let event = LifeEvent(id: editing?.id ?? UUID(),
                              name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                              kind: kind, budget: amount, startDate: startDate, endDate: endDate,
                              completedAt: editing?.completedAt,
                              completionSpent: editing?.completionSpent,
                              createdAt: editing?.createdAt ?? .now)
        if store.saveLifeEvent(event) { dismiss() }
    }
}

private struct LifeEventDetail: View {
    @ObservedObject var store: LedgerStore
    let eventID: UUID
    @State private var showingEdit = false
    @State private var showingComplete = false

    private var event: LifeEvent? { store.lifeEvents.first { $0.id == eventID } }

    var body: some View {
        Group {
            if let event {
                let expenses = event.expenses(in: store.entries).sorted { $0.date > $1.date }
                let spent = event.completionSpent ?? event.spent(in: store.entries)
                let remaining = event.budget - spent
                List {
                    Section("Progress") {
                        LabeledContent("Budget", value: LKR.string(event.budget))
                        LabeledContent(event.completedAt == nil ? "Spent" : "Spent at completion",
                                       value: LKR.string(spent))
                        LabeledContent(remaining < 0 ? "Over budget" : "Remaining",
                                       value: LKR.string(abs(remaining)))
                        ProgressView(value: min(1, max(0, NSDecimalNumber(decimal: spent / event.budget).doubleValue)))
                            .tint(remaining < 0 ? Palette.coral : Palette.cranberry)
                        Text("\(event.startDate.formatted(date: .abbreviated, time: .omitted)) – \(event.endDate.formatted(date: .abbreviated, time: .omitted))")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let completedAt = event.completedAt {
                            Label("Completed \(completedAt.formatted(date: .abbreviated, time: .omitted))", systemImage: "checkmark.seal.fill")
                        }
                    }
                    if !expenses.isEmpty {
                        Section("By category") {
                            ForEach(Array(Dictionary(grouping: expenses, by: \.category)
                                .map { (name: $0.key, amount: $0.value.reduce(Decimal.zero) { $0 + $1.amount }) }
                                .sorted { $0.amount > $1.amount }), id: \.name) { item in
                                LabeledContent(item.name, value: LKR.string(item.amount))
                            }
                        }
                        Section("Transactions") {
                            ForEach(expenses) { entry in
                                NavigationLink { EntryDetail(store: store, entry: entry) } label: {
                                    EntryRow(entry: entry)
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView("No event expenses yet", systemImage: "tray",
                                               description: Text("Choose this event when you add an expense."))
                    }
                    if event.completedAt == nil {
                        Section {
                            Button("Complete event") { showingComplete = true }
                        }
                    }
                }
                .navigationTitle(event.name)
                .toolbar {
                    if event.completedAt == nil {
                        Button("Edit") { showingEdit = true }
                    }
                }
                .sheet(isPresented: $showingEdit) {
                    NavigationStack { LifeEventEditor(store: store, editing: event) }
                }
                .confirmationDialog("Complete this event?", isPresented: $showingComplete) {
                    Button("Complete event") { _ = store.completeLifeEvent(event) }
                } message: {
                    Text("Ledgerly will save this event’s final total. Its linked expenses can no longer be edited or deleted.")
                }
            }
        }
    }
}
