import SwiftUI

struct RemindersScreen: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject private var notifications: LedgerNotificationService
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var editing: LedgerReminder?
    @State private var showingNew = false
    @State private var search = ""
    @State private var filter: ReminderAgendaFilter = .all
    @State private var frequency: ReminderFrequency?

    init(store: LedgerStore) {
        self.store = store
        self.notifications = store.notifications
    }

    private var hasFilters: Bool { filter != .all || frequency != nil }
    private var isNarrowed: Bool { hasFilters || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let agenda = ReminderAgenda.items(store.reminders, asOf: context.date,
                search: search, filter: filter, frequency: frequency)
            List {
                Section {
                    NavigationLink {
                        BudgetQuietHoursScreen(notifications: notifications)
                    } label: {
                        Label("Quiet hours", systemImage: "moon.fill")
                    }
                    Text(notifications.quietReminderSounds && notifications.budgetQuietHours.enabled
                        ? "Payment reminders inside quiet hours appear without sound at their selected times."
                        : "Payment reminders use their selected times and normal notification sounds.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if store.reminders.isEmpty {
                    ContentUnavailableView("No reminders yet", systemImage: "bell",
                                           description: Text("Add a bill or payment reminder to be notified when it is due."))
                } else if agenda.isEmpty {
                    ContentUnavailableView("No matching reminders", systemImage: "magnifyingglass",
                        description: Text("Try a different name or change the reminder filters."))
                    Button("Clear search and filters") { clearFilters() }
                } else {
                    if isNarrowed {
                        Section {
                            Text("Showing \(agenda.count) of \(store.reminders.count) reminders")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("Clear search and filters") { clearFilters() }
                        }
                    }
                    ForEach(ReminderAgendaGroup.allCases, id: \.self) { group in
                        let rows = agenda.filter { $0.group == group }
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { item in reminderRow(item) }
                                    .onDelete { offsets in
                                        let selected = offsets.map { rows[$0].reminder }
                                        selected.forEach(store.deleteReminder)
                                    }
                            } header: {
                                Text(group.title)
                            } footer: {
                                if group == .upcoming {
                                    Text("Scheduled in this device's local time. iOS controls notification delivery. A reminder does not record a payment.")
                                } else if group == .needsAttention {
                                    Text("These schedules have no future occurrence. Edit the date or delete the reminder; a past time does not tell Ledgerly whether you paid.")
                                }
                            }
                        }
                    }
                }
            }
            .disabled(notifications.isUpdatingPreferences)
        }
        .navigationTitle("Reminders")
        .searchable(text: $search, prompt: "Search reminder name")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(ReminderAgendaFilter.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Repeat", selection: $frequency) {
                        Text("Any schedule").tag(Optional<ReminderFrequency>.none)
                        ForEach(ReminderFrequency.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    if isNarrowed { Button("Clear search and filters") { clearFilters() } }
                } label: {
                    Label("Filters", systemImage: hasFilters
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Reminder filters")
                .accessibilityValue(hasFilters ? "Filters applied" : "All reminders")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { showingNew = true }
            }
        }
        .sheet(isPresented: $showingNew) { ReminderEditor(store: store, reminder: nil) }
        .sheet(item: $editing) { ReminderEditor(store: store, reminder: $0) }
        .onChange(of: store.categoryLearningScope) { _, _ in
            editing = nil
            showingNew = false
            clearFilters()
        }
    }

    private func clearFilters() {
        search = ""
        filter = .all
        frequency = nil
    }

    @ViewBuilder
    private func reminderRow(_ item: ReminderAgendaItem) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                reminderDetails(item)
                reminderControl(item)
            }
        } else {
            HStack(spacing: 12) {
                reminderDetails(item)
                reminderControl(item)
            }
        }
    }

    private func reminderDetails(_ item: ReminderAgendaItem) -> some View {
        let reminder = item.reminder
        return HStack(alignment: .top, spacing: 12) {
            LedgerIconTile(icon: .init(symbol: reminder.isPaused ? "bell.slash.fill" : "bell.badge.fill",
                color: reminder.isPaused ? Palette.iconPlum : Palette.cranberry), size: 42)
            Button { editing = reminder } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(reminder.title).font(.headline)
                    Text(detail(for: reminder)).font(.subheadline).foregroundStyle(.secondary)
                    if !reminder.isPaused && notifications.budgetPreferences.silencesReminder(
                        hour: reminder.hour, minute: reminder.minute) {
                        Text("Silent during quiet hours").font(.footnote).foregroundStyle(.secondary)
                    }
                    if item.group == .upcoming, let next = item.nextDate {
                        Text("Next: \(next.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline.weight(.medium)).foregroundStyle(Palette.cranberry)
                    } else if reminder.isPaused {
                        Text("Paused — notifications are off").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("No future scheduled time").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit this payment reminder")
        }
    }

    @ViewBuilder
    private func reminderControl(_ item: ReminderAgendaItem) -> some View {
        if item.nextDate != nil {
            Button(item.reminder.isPaused ? "Resume" : "Pause") {
                Task { await store.setReminderPaused(item.reminder, paused: !item.reminder.isPaused) }
            }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.medium))
            .frame(minHeight: 44)
            .accessibilityLabel("\(item.reminder.isPaused ? "Resume" : "Pause") \(item.reminder.title)")
        }
    }

    private func detail(for reminder: LedgerReminder) -> String {
        let amount = reminder.amount.map { " · \(LKR.string($0))" } ?? ""
        let time = Calendar.current.date(bySettingHour: reminder.hour, minute: reminder.minute,
            second: 0, of: .now)?.formatted(date: .omitted, time: .shortened) ?? "selected time"
        switch reminder.frequency {
        case .monthly: return "Every month on day \(reminder.dayOfMonth) at \(time)\(amount)"
        case .weekly:
            let days = Calendar.current.weekdaySymbols
            let day = (1...days.count).contains(reminder.weekday) ? days[reminder.weekday - 1] : "selected weekday"
            return "Every \(day) at \(time)\(amount)"
        case .once: return "\(reminder.date.formatted(date: .abbreviated, time: .omitted)) at \(time)\(amount)"
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
    @State private var editorScope: UUID

    init(store: LedgerStore, reminder: LedgerReminder?) {
        self.store = store
        _editorScope = State(initialValue: store.categoryLearningScope)
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
                    Button("Save") { save() }.disabled(isSaving || editorScope != store.categoryLearningScope)
                }
            }
            .onChange(of: store.categoryLearningScope) { _, _ in dismiss() }
        }
    }

    private func save() {
        guard editorScope == store.categoryLearningScope else { dismiss(); return }
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
