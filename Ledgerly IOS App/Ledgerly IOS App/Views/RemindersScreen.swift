import SwiftUI

struct RemindersScreen: View {
    @ObservedObject var store: LedgerStore
    @State private var editing: LedgerReminder?
    @State private var showingNew = false

    var body: some View {
        List {
            if store.reminders.isEmpty {
                ContentUnavailableView("No reminders yet", systemImage: "bell",
                                       description: Text("Add a bill or payment reminder to be notified when it is due."))
            } else {
                ForEach(store.reminders) { reminder in
                    HStack(spacing: 12) {
                        LedgerIconTile(icon: .init(symbol: reminder.isPaused ? "bell.slash.fill" : "bell.badge.fill",
                                                   color: reminder.isPaused ? Palette.iconPlum : Palette.cranberry), size: 42)
                        Button { editing = reminder } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(reminder.title).font(.headline)
                                Text(detail(for: reminder)).font(.subheadline).foregroundStyle(.secondary)
                                if reminder.isPaused { Text("Paused").font(.caption).foregroundStyle(.secondary) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Button(reminder.isPaused ? "Resume" : "Pause") {
                            Task { await store.setReminderPaused(reminder, paused: !reminder.isPaused) }
                        }
                        .font(.caption)
                    }
                    .accessibilityElement(children: .combine)
                }
                .onDelete { offsets in
                    let selected = offsets.map { store.reminders[$0] }
                    selected.forEach(store.deleteReminder)
                }
            }
        }
        .navigationTitle("Reminders")
        .toolbar { Button("Add", systemImage: "plus") { showingNew = true } }
        .sheet(isPresented: $showingNew) { ReminderEditor(store: store, reminder: nil) }
        .sheet(item: $editing) { ReminderEditor(store: store, reminder: $0) }
    }

    private func detail(for reminder: LedgerReminder) -> String {
        let amount = reminder.amount.map { " · \(LKR.string($0))" } ?? ""
        switch reminder.frequency {
        case .monthly: return "Every month on day \(reminder.dayOfMonth)\(amount)"
        case .weekly: return "Every \(Calendar.current.weekdaySymbols[reminder.weekday - 1])\(amount)"
        case .once: return "\(reminder.date.formatted(date: .abbreviated, time: .omitted))\(amount)"
        }
    }
}

private struct ReminderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    @State private var draft: LedgerReminder
    @State private var amountText: String
    @State private var time: Date
    @State private var isSaving = false
    @State private var validationError: String?

    init(store: LedgerStore, reminder: LedgerReminder?) {
        self.store = store
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        let initial = reminder ?? LedgerReminder(id: UUID(), title: "", amount: nil,
                                                  frequency: .monthly, dayOfMonth: 1, weekday: 2,
                                                  date: tomorrow, hour: 9, minute: 0, isPaused: false)
        _draft = State(initialValue: initial)
        _amountText = State(initialValue: initial.amount.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
        _time = State(initialValue: Calendar.current.date(bySettingHour: initial.hour,
                                                          minute: initial.minute, second: 0, of: .now) ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Payment") {
                    TextField("Name, for example mobile bill", text: $draft.title)
                    TextField("Amount in LKR (optional)", text: $amountText).keyboardType(.decimalPad)
                }
                Section("Schedule") {
                    Picker("Repeat", selection: $draft.frequency) {
                        ForEach(ReminderFrequency.allCases) { frequency in
                            Text(frequency.title).tag(frequency)
                        }
                    }
                    switch draft.frequency {
                    case .monthly:
                        Stepper("Day \(draft.dayOfMonth) of each month", value: $draft.dayOfMonth, in: 1...28)
                        Text("Days 1–28 repeat in every month.").font(.footnote).foregroundStyle(.secondary)
                    case .weekly:
                        Picker("Weekday", selection: $draft.weekday) {
                            ForEach(1...7, id: \.self) { day in
                                Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                            }
                        }
                    case .once:
                        DatePicker("Date", selection: $draft.date, in: Date.now..., displayedComponents: .date)
                    }
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    Toggle("Paused", isOn: $draft.isPaused)
                }
                if let validationError {
                    Text(validationError).foregroundStyle(.red)
                }
            }
            .navigationTitle("Reminder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(isSaving)
                }
            }
        }
    }

    private func save() {
        let cleanAmount = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanAmount.isEmpty {
            guard let amount = Decimal(string: cleanAmount.replacingOccurrences(of: ",", with: ".")), amount >= 0 else {
                validationError = "Enter a valid amount or leave it blank."
                return
            }
            draft.amount = amount
        } else {
            draft.amount = nil
        }
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        draft.hour = components.hour ?? 9
        draft.minute = components.minute ?? 0
        guard draft.isValid else {
            validationError = "Enter a name and a future date for a one-time reminder."
            return
        }
        isSaving = true
        Task {
            if await store.saveReminder(draft) { dismiss() }
            isSaving = false
        }
    }
}
