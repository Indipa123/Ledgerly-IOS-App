import SwiftUI
import ActivityKit

struct ShoppingTripScreen: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var trips: ShoppingTripStore
    @State private var name = ""
    @State private var capText = ""
    @State private var categoryID: UUID?
    @State private var eventID: UUID?
    @State private var placeID: UUID?
    @State private var itemName = ""
    @State private var priceText = ""
    @State private var quantity = 1
    @State private var confirmingFinish = false
    @State private var confirmingDiscard = false
    @State private var editingItem: ShoppingItem?
    @State private var finishedTrip: ShoppingTrip?

    private var categories: [LedgerCategory] { store.activeCategories(for: .expense) }
    private var cap: Decimal? { Self.positiveAmount(capText) }
    private var price: Decimal? { Self.positiveAmount(priceText) }

    var body: some View {
        Form {
            if let trip = trips.activeTrip {
                activeSections(trip)
            } else {
                startSections
            }
        }
        .navigationTitle("Shopping trip")
        .onAppear {
            categoryID = categoryID ?? categories.first(where: { $0.name == "Groceries" })?.id ?? categories.first?.id
            if let trip = trips.activeTrip, store.entries.contains(where: { $0.id == trip.id }) {
                trips.finish() // The expense was committed before a previous interruption.
            }
        }
        .alert("Shopping trip error", isPresented: Binding(
            get: { trips.error != nil }, set: { if !$0 { trips.error = nil } }
        )) { Button("OK") { trips.error = nil } } message: {
            Text(trips.error ?? "Please try again.")
        }
        .confirmationDialog("Save this trip as one expense?", isPresented: $confirmingFinish) {
            Button("Save expense") { saveTrip() }
        } message: {
            if let trip = trips.activeTrip {
                Text(finishMessage(trip))
            }
        }
        .confirmationDialog("Discard this trip?", isPresented: $confirmingDiscard) {
            Button("Discard trip", role: .destructive) { trips.discard() }
        } message: {
            Text("The items and spending cap will be removed. No expense will be saved.")
        }
        .sheet(item: $editingItem) { item in
            NavigationStack { ShoppingItemEditor(item: item, trips: trips) }
        }
        .sheet(item: $finishedTrip) { trip in
            NavigationStack { ShoppingTripSummary(store: store, trip: trip) }
        }
    }

    private var startSections: some View {
        Group {
            Section {
                TextField("Trip name", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("Spending cap in LKR", text: $capText)
                    .keyboardType(.decimalPad)
                Picker("Expense category", selection: $categoryID) {
                    Text("Choose a category").tag(Optional<UUID>.none)
                    ForEach(categories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                Picker("Event budget (optional)", selection: $eventID) {
                    Text("No event").tag(Optional<UUID>.none)
                    ForEach(store.lifeEvents.filter { $0.completedAt == nil }) { event in
                        Text(event.name).tag(Optional(event.id))
                    }
                }
                Picker("Place (optional)", selection: $placeID) {
                    Text("No place").tag(Optional<UUID>.none)
                    ForEach(store.places) { place in
                        Text(place.name).tag(Optional(place.id))
                    }
                }
            } header: { Text("Plan a trip") } footer: {
                Text("Track items as you shop. Finish to record one expense in your monthly totals.")
            }
            Section {
                Button("Start shopping") {
                    guard let cap, let categoryID else { return }
                    let location = store.places.first(where: { $0.id == placeID })?.location
                    _ = trips.start(name: name, cap: cap, categoryID: categoryID,
                                    eventID: eventID, location: location)
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cap == nil || categoryID == nil)
            }
        }
    }

    @ViewBuilder
    private func activeSections(_ trip: ShoppingTrip) -> some View {
        Section("\(trip.name) · started \(trip.startedAt.formatted(date: .abbreviated, time: .shortened))") {
            LabeledContent("Cap", value: LKR.string(trip.cap))
            if let location = trip.location {
                LabeledContent("Place", value: location.name)
            }
            LabeledContent("Items total", value: LKR.string(trip.spent))
            LabeledContent(trip.remaining >= 0 ? "Remaining" : "Over cap",
                           value: LKR.string(abs(trip.remaining)))
                .foregroundStyle(trip.remaining < 0 ? Palette.coral : Palette.ink)
            ProgressView(value: min(1, max(0, NSDecimalNumber(decimal: trip.spent / trip.cap).doubleValue)))
                .tint(trip.remaining < 0 ? Palette.coral : Palette.cranberry)
                .accessibilityLabel("Shopping cap progress")
        }
        Section("Add item") {
            TextField("Item name", text: $itemName)
            TextField("Price per item in LKR", text: $priceText)
                .keyboardType(.decimalPad)
            Stepper("Quantity: \(quantity)", value: $quantity, in: 1...999)
            Button("Add item") {
                guard let price else { return }
                if trips.addItem(name: itemName, unitPrice: price, quantity: quantity) {
                    itemName = ""
                    priceText = ""
                    quantity = 1
                }
            }
            .disabled(itemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || price == nil)
        }
        Section("Lock Screen quick add") {
            Stepper("Add \(LKR.string(Decimal(trip.quickAddValue)))", value: Binding(
                get: { trip.quickAddValue }, set: { trips.changeQuickAddAmount($0) }
            ), in: 50...100_000, step: 50)
            Text("The Lock Screen button adds an item for this amount. Open the trip to rename or adjust it later.")
                .font(.footnote).foregroundStyle(.secondary)
            if !ActivityAuthorizationInfo().areActivitiesEnabled {
                Text("Live Activities are off on this device. You can still track the trip here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        Section("Items") {
            if trip.items.isEmpty {
                Text("No items yet").foregroundStyle(.secondary)
            } else {
                ForEach(trip.items) { item in
                    Button { editingItem = item } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name)
                                Text("\(item.quantity) × \(LKR.string(item.unitPrice))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(LKR.string(item.total)).monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Remove", role: .destructive) { trips.removeItem(id: item.id) }
                    }
                }
            }
        }
        Section("Expense details") {
            if !categories.contains(where: { $0.id == trip.categoryID }) {
                Text("The selected category was archived. Choose an active category to finish.")
                    .font(.footnote).foregroundStyle(Palette.coral)
            }
            Picker("Category", selection: Binding(
                get: { trip.categoryID }, set: { trips.changeCategory($0) }
            )) {
                ForEach(categories) { category in
                    Text(category.name).tag(category.id)
                }
            }
            Picker("Event budget", selection: Binding(
                get: { trip.eventID }, set: { trips.changeEvent($0) }
            )) {
                Text("No event").tag(Optional<UUID>.none)
                ForEach(store.lifeEvents.filter { $0.completedAt == nil }) { event in
                    Text(event.name).tag(Optional(event.id))
                }
            }
            Picker("Place", selection: Binding(
                get: { trip.location?.placeID },
                set: { id in
                    trips.changeLocation(store.places.first(where: { $0.id == id })?.location)
                }
            )) {
                Text("No place").tag(Optional<UUID>.none)
                ForEach(store.places) { place in
                    Text(place.name).tag(Optional(place.id))
                }
                if let location = trip.location,
                   let id = location.placeID,
                   !store.places.contains(where: { $0.id == id }) {
                    Text("\(location.name) (removed)").tag(Optional(id))
                }
            }
            if let location = trip.location,
               !store.places.contains(where: { $0.id == location.placeID }) {
                Text("The saved place was removed. The original location will still be attached unless you choose another place or No place.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if trip.eventID != nil && !store.lifeEvents.contains(where: {
                $0.id == trip.eventID && $0.completedAt == nil
            }) {
                Text("This event has ended. Choose another event or No event to finish.")
                    .font(.footnote).foregroundStyle(Palette.coral)
            }
            Text("All items will be kept in the expense note. The expense is saved only when you finish.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
            Button("Finish and save expense") { confirmingFinish = true }
                .disabled(trip.items.isEmpty || !categories.contains(where: { $0.id == trip.categoryID }) ||
                          (trip.eventID != nil && !store.lifeEvents.contains(where: {
                              $0.id == trip.eventID && $0.completedAt == nil
                          })))
            Button("Discard trip", role: .destructive) { confirmingDiscard = true }
        }
    }

    private func finishMessage(_ trip: ShoppingTrip) -> String {
        var message = "Save \(LKR.string(trip.spent)) for \(trip.items.count) item(s)."
        if trip.remaining < 0 { message += " This is \(LKR.string(-trip.remaining)) over your trip cap." }
        if let event = store.lifeEvents.first(where: { $0.id == trip.eventID }),
           event.spent(in: store.entries) + trip.spent > event.budget {
            message += " This also exceeds the \(event.name) event budget."
        }
        return message
    }

    private func saveTrip() {
        guard let trip = trips.activeTrip, !trip.items.isEmpty,
              let category = categories.first(where: { $0.id == trip.categoryID }) else { return }
        let event = store.lifeEvents.first { $0.id == trip.eventID }
        let overEvent = event.map { $0.spent(in: store.entries) + trip.spent > $0.budget } ?? false
        let entry = LedgerEntry(id: trip.id, kind: .expense, amount: trip.spent,
                                title: trip.name, category: category.name, date: .now,
                                note: trip.expenseNote, categoryID: category.id,
                                location: trip.location,
                                eventID: trip.eventID,
                                budgetOverrideReason: overEvent ? "Shopping trip total confirmed over event budget" : nil)
        if store.save(entry) {
            trips.finish()
            finishedTrip = trip
        }
    }

    private static func positiveAmount(_ text: String) -> Decimal? {
        guard let amount = Decimal(string: text.replacingOccurrences(of: ",", with: ".")),
              amount > 0 else { return nil }
        return amount
    }
}

private struct ShoppingTripSummary: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    let trip: ShoppingTrip

    private var savedEntry: LedgerEntry? { store.entries.first { $0.id == trip.id } }

    var body: some View {
        Form {
            Section("Trip complete") {
                LabeledContent("Spent", value: LKR.string(trip.spent))
                LabeledContent("Spending cap", value: LKR.string(trip.cap))
                LabeledContent(trip.remaining < 0 ? "Over cap" : "Left from cap",
                               value: LKR.string(abs(trip.remaining)))
                if let savedEntry {
                    LabeledContent("Category", value: savedEntry.category)
                }
                if let event = store.lifeEvents.first(where: { $0.id == trip.eventID }) {
                    LabeledContent("Event budget", value: event.name)
                }
                if let location = trip.location {
                    LabeledContent("Place", value: location.name)
                }
                Text("One expense was saved to your monthly totals. The item details are kept in its note.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Items") {
                ForEach(trip.items) { item in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                            Text("\(item.quantity) × \(LKR.string(item.unitPrice))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Text(LKR.string(item.total)).monospacedDigit()
                    }
                }
            }
            if let savedEntry {
                Section {
                    NavigationLink {
                        EntryDetail(store: store, entry: savedEntry)
                    } label: {
                        Label("View saved expense", systemImage: "receipt")
                    }
                }
            }
        }
        .navigationTitle("Trip summary")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

private struct ShoppingItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    let item: ShoppingItem
    @ObservedObject var trips: ShoppingTripStore
    @State private var name: String
    @State private var priceText: String
    @State private var quantity: Int

    init(item: ShoppingItem, trips: ShoppingTripStore) {
        self.item = item
        self.trips = trips
        _name = State(initialValue: item.name)
        _priceText = State(initialValue: NSDecimalNumber(decimal: item.unitPrice).stringValue)
        _quantity = State(initialValue: item.quantity)
    }

    private var price: Decimal? {
        guard let value = Decimal(string: priceText.replacingOccurrences(of: ",", with: ".")),
              value > 0 else { return nil }
        return value
    }

    var body: some View {
        Form {
            TextField("Item name", text: $name)
            TextField("Price per item in LKR", text: $priceText).keyboardType(.decimalPad)
            Stepper("Quantity: \(quantity)", value: $quantity, in: 1...999)
        }
        .navigationTitle("Edit item")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let price else { return }
                    var updated = item
                    updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.unitPrice = price
                    updated.quantity = quantity
                    if trips.updateItem(updated) { dismiss() }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || price == nil)
            }
        }
    }
}
