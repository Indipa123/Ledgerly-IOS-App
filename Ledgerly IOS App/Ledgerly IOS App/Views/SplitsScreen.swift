import SwiftUI

struct SplitsScreen: View {
    @ObservedObject var store: LedgerStore
    @State private var showingNew = false
    @State private var showingFriends = false

    var body: some View {
        List {
            let balances = store.friends.compactMap { friend -> (LedgerFriend, Decimal)? in
                let amount = store.splitBills.flatMap(\.shares)
                    .filter { $0.friendID == friend.id && $0.settledAt == nil }
                    .reduce(Decimal.zero) { $0 + $1.amount }
                return amount > 0 ? (friend, amount) : nil
            }
            if !balances.isEmpty {
                Section("Friends owe you") {
                    ForEach(balances, id: \.0.id) { friend, amount in
                        LabeledContent(friend.name, value: LKR.string(amount))
                    }
                }
            }
            if store.splitBills.isEmpty {
                ContentUnavailableView("No shared expenses yet", systemImage: "person.2",
                                       description: Text("Split an expense with friends and track what they owe you."))
                Button("Create a split") { showingNew = true }
            } else {
                Section("Shared expenses") {
                    ForEach(store.splitBills) { bill in
                        NavigationLink { SplitDetail(store: store, billID: bill.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(store.entries.first(where: { $0.id == bill.entryID })?.displayTitle ?? "Shared expense")
                                    .font(.headline)
                                Text("\(LKR.string(bill.totalAmount)) total · \(LKR.string(bill.outstanding)) still owed")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            }
            Section {
                NavigationLink { FriendsScreen(store: store) } label: {
                    Label("Manage friends", systemImage: "person.2.fill")
                }
            } footer: {
                Text("Friends do not need an account. Settling a share records repayment here; it does not move money or create income.")
            }
        }
        .navigationTitle("Split with friends")
        .toolbar {
            Button { showingNew = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("Create a split")
        }
        .sheet(isPresented: $showingNew) {
            NavigationStack { SplitEditor(store: store) }
        }
    }
}

struct SplitEditor: View {
    private enum Method: String, CaseIterable, Identifiable {
        case equal = "Equal", amounts = "Amounts", percentage = "Percentage"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    var editing: SplitBill? = nil
    var initialEntryID: UUID? = nil
    @State private var entryID: UUID?
    @State private var selectedFriends: Set<UUID> = []
    @State private var method: Method = .equal
    @State private var amounts: [UUID: String] = [:]
    @State private var percentages: [UUID: String] = [:]
    @State private var note = ""
    @State private var showingFriendEditor = false
    @State private var loaded = false

    private var entry: LedgerEntry? { store.entries.first { $0.id == entryID } }
    private var availableEntries: [LedgerEntry] {
        store.entries.filter { item in
            item.kind == .expense &&
                (!store.splitBills.contains(where: { $0.entryID == item.id }) || item.id == editing?.entryID)
        }
    }
    private var chosenFriends: [LedgerFriend] {
        store.friends.filter { selectedFriends.contains($0.id) }
    }
    private var percentageValues: [(UUID, Decimal)]? {
        let values = chosenFriends.compactMap { friend -> (UUID, Decimal)? in
            guard let value = SplitMath.percentageInput(percentages[friend.id] ?? "") else { return nil }
            return (friend.id, value)
        }
        return values.count == chosenFriends.count ? values : nil
    }
    private var remainingPercentage: Decimal? {
        guard let values = percentageValues else { return nil }
        let remainder = 100 - values.reduce(Decimal.zero) { $0 + $1.1 }
        return remainder >= 0 ? remainder : nil
    }
    private var proposedShares: [SplitShare]? {
        guard let entry, !chosenFriends.isEmpty else { return nil }
        if method == .equal { return SplitMath.equal(total: entry.amount, friendIDs: chosenFriends.map(\.id)) }
        if method == .percentage {
            guard let values = percentageValues else { return nil }
            return SplitMath.percentage(total: entry.amount, friendPercentages: values)
        }
        let values = chosenFriends.compactMap { friend -> (UUID, Decimal)? in
            guard let value = Decimal(string: (amounts[friend.id] ?? "").replacingOccurrences(of: ",", with: "."))
            else { return nil }
            return (friend.id, value)
        }
        guard values.count == chosenFriends.count else { return nil }
        return SplitMath.custom(total: entry.amount, friendAmounts: values)
    }

    var body: some View {
        Form {
            Section("Expense") {
                if let initialEntryID, editing == nil {
                    Text(store.entries.first(where: { $0.id == initialEntryID })?.displayTitle ?? "Expense")
                } else {
                    Picker("Transaction", selection: $entryID) {
                        Text("Choose an expense").tag(Optional<UUID>.none)
                        ForEach(availableEntries) { item in
                            Text("\(item.displayTitle) · \(LKR.string(item.amount))").tag(Optional(item.id))
                        }
                    }
                }
                if let entry { LabeledContent("Total", value: LKR.string(entry.amount)) }
            }
            Section("Friends") {
                ForEach(store.friends.filter { !$0.isArchived || selectedFriends.contains($0.id) }) { friend in
                    Toggle(friend.name, isOn: Binding(
                        get: { selectedFriends.contains(friend.id) },
                        set: { selected in
                            if selected { selectedFriends.insert(friend.id) }
                            else { selectedFriends.remove(friend.id) }
                        }))
                }
                Button("Add friend") { showingFriendEditor = true }
            }
            if !selectedFriends.isEmpty {
                Section("Shares") {
                    Picker("Method", selection: $method) {
                        ForEach(Method.allCases) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    if method == .amounts {
                        ForEach(chosenFriends) { friend in
                            TextField("\(friend.name)'s share in LKR", text: Binding(
                                get: { amounts[friend.id] ?? "" },
                                set: { amounts[friend.id] = $0 }))
                                .keyboardType(.decimalPad)
                        }
                    }
                    if method == .percentage {
                        ForEach(chosenFriends) { friend in
                            LabeledContent(friend.name) {
                                HStack {
                                    TextField("0–100", text: Binding(
                                        get: { percentages[friend.id] ?? "" },
                                        set: { percentages[friend.id] = $0 }))
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(minWidth: 70)
                                        .accessibilityLabel("\(friend.name)'s percentage")
                                    Text("%").foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let remaining = remainingPercentage {
                            LabeledContent("Your percentage", value: "\(NSDecimalNumber(decimal: remaining).stringValue)%")
                        }
                        Text("Enter each friend's percentage, up to two decimal places. The rest is yours. Friends' amounts round down to cents; any rounding remainder stays in your share.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("Percentages calculate the saved amounts. When you edit later, Ledgerly shows those amounts.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let shares = proposedShares {
                        LabeledContent("Your share", value: LKR.string(shares.first { $0.friendID == nil }?.amount ?? 0))
                        ForEach(chosenFriends) { friend in
                            let share = shares.first { $0.friendID == friend.id }
                            LabeledContent("\(friend.name) owes you", value: LKR.string(share?.amount ?? 0))
                        }
                    } else if entry != nil {
                        Text(method == .percentage
                             ? "Enter a percentage from 0 to 100 for each friend. Their combined percentage cannot exceed 100%."
                             : "Enter valid amounts. Friends' shares cannot exceed the expense total.")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            Section("Optional note") { TextField("What was shared?", text: $note) }
            Section {
                Text("The original expense stays in your monthly totals once. Shares track repayment separately.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(editing == nil ? "New split" : "Edit split")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(proposedShares == nil)
            }
        }
        .sheet(isPresented: $showingFriendEditor) {
            NavigationStack {
                FriendEditor(store: store) { friend in selectedFriends.insert(friend.id) }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            entryID = editing?.entryID ?? initialEntryID
            guard let editing else { return }
            selectedFriends = Set(editing.shares.compactMap(\.friendID))
            note = editing.note
            // The persisted amounts are authoritative, including cent rounding and settlements.
            method = .amounts
            for share in editing.shares where share.friendID != nil {
                if let friendID = share.friendID {
                    amounts[friendID] = NSDecimalNumber(decimal: share.amount).stringValue
                }
            }
        }
    }

    private func save() {
        guard let entry, let shares = proposedShares else { return }
        let preserved = shares.map { share -> SplitShare in
            guard let old = editing?.shares.first(where: { $0.friendID == share.friendID && $0.amount == share.amount })
            else { return share }
            return old
        }
        let bill = SplitBill(id: editing?.id ?? UUID(), entryID: entry.id,
                             totalAmount: entry.amount, note: note, shares: preserved,
                             createdAt: editing?.createdAt ?? .now)
        if store.saveSplitBill(bill) { dismiss() }
    }
}

struct SplitDetail: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    let billID: UUID
    @State private var editing = false
    @State private var deleting = false

    private var bill: SplitBill? { store.splitBills.first { $0.id == billID } }

    var body: some View {
        Group {
            if let bill {
                List {
                    Section("Summary") {
                        LabeledContent("Total expense", value: LKR.string(bill.totalAmount))
                        LabeledContent("Your share", value: LKR.string(bill.ownShare))
                        LabeledContent("Still owed to you", value: LKR.string(bill.outstanding))
                        if !bill.note.isEmpty { Text(bill.note) }
                        if let entry = store.entries.first(where: { $0.id == bill.entryID }) {
                            NavigationLink { EntryDetail(store: store, entry: entry) } label: {
                                Label("View expense", systemImage: "receipt")
                            }
                        }
                    }
                    Section("Friends") {
                        ForEach(bill.shares.filter { $0.friendID != nil }) { share in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(store.friends.first(where: { $0.id == share.friendID })?.name ?? "Friend")
                                    Spacer()
                                    Text(LKR.string(share.amount)).monospacedDigit()
                                }
                                Button(share.settledAt == nil ? "Mark settled" : "Undo settlement") {
                                    store.settleShare(billID: bill.id, shareID: share.id,
                                                      settled: share.settledAt == nil)
                                }
                                .font(.subheadline)
                                if let date = share.settledAt {
                                    Text("Settled \(date.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section {
                        Button("Remove split", role: .destructive) { deleting = true }
                    }
                }
                .navigationTitle(store.entries.first(where: { $0.id == bill.entryID })?.displayTitle ?? "Split")
                .toolbar { Button("Edit") { editing = true } }
                .sheet(isPresented: $editing) {
                    NavigationStack { SplitEditor(store: store, editing: bill) }
                }
                .confirmationDialog("Remove this split?", isPresented: $deleting) {
                    Button("Remove split", role: .destructive) {
                        store.deleteSplitBill(id: bill.id)
                        dismiss()
                    }
                } message: {
                    Text("The original expense remains saved. Settlement history for this split will be removed.")
                }
            }
        }
    }
}

private struct FriendsScreen: View {
    @ObservedObject var store: LedgerStore
    @State private var showingNew = false
    @State private var editing: LedgerFriend?

    var body: some View {
        List {
            if store.friends.isEmpty {
                ContentUnavailableView("No friends yet", systemImage: "person.crop.circle.badge.plus",
                                       description: Text("Add a friend by name to share an expense."))
            }
            ForEach(store.friends) { friend in
                Button { editing = friend } label: {
                    HStack {
                        Text(friend.name)
                        if friend.isArchived { Text("Archived").foregroundStyle(.secondary) }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Friends")
        .toolbar {
            Button { showingNew = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add friend")
        }
        .sheet(isPresented: $showingNew) { NavigationStack { FriendEditor(store: store) } }
        .sheet(item: $editing) { friend in NavigationStack { FriendEditor(store: store, editing: friend) } }
    }
}

struct FriendEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    var editing: LedgerFriend? = nil
    var onSave: ((LedgerFriend) -> Void)? = nil
    @State private var name = ""
    @State private var isArchived = false

    var body: some View {
        Form {
            TextField("Friend's name", text: $name)
            if editing != nil { Toggle("Archived", isOn: $isArchived) }
            Text("Friends do not need to install Ledgerly. Names are entered by you.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle(editing == nil ? "Add friend" : "Edit friend")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let friend = LedgerFriend(id: editing?.id ?? UUID(),
                                              name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                              isArchived: isArchived,
                                              createdAt: editing?.createdAt ?? .now)
                    if store.saveFriend(friend) { onSave?(friend); dismiss() }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            name = editing?.name ?? ""
            isArchived = editing?.isArchived ?? false
        }
    }
}
