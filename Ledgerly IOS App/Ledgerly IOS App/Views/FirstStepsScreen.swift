import SwiftUI
import FirebaseAuth

/// Optional setup uses the regular editors; opening or skipping this screen writes no data.
struct FirstStepsScreen: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var auth: AuthSession
    var finish: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var editor: Step?

    private enum Step: String, Identifiable {
        case income, budget
        var id: String { rawValue }
    }

    private var hasIncome: Bool { store.entries.contains { $0.kind == .income && $0.amount > 0 } }
    private var hasBudget: Bool { store.budget > 0 }
    private var ready: Bool {
        guard auth.isReady, !auth.isBusy else { return false }
        return auth.user.map { !store.hasUnconfirmedSync(for: $0.uid) } ?? true
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.largeTitle).foregroundStyle(Palette.cranberry)
                    Text("Start with your money").font(.title2.bold())
                    Text("Two optional steps to make your dashboard useful from day one.")
                        .foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }
            Section {
                setupRow("Record your first income",
                         subtitle: hasIncome ? "You already have saved income." : "Add money you have actually received, such as salary.",
                         symbol: "arrow.down.left", complete: hasIncome, step: .income)
                setupRow("Set this month's budget",
                         subtitle: hasBudget ? "Current budget: \(LKR.string(store.budget))" : "Choose how much you plan to spend this month.",
                         symbol: "chart.pie.fill", complete: hasBudget, step: .budget)
            } header: {
                Text("Your first steps")
            } footer: {
                Text("Each editor saves only when you choose Save. Existing income and budgets are recognised. You can change them later from Home or Transactions.")
            }
            if !ready {
                Section {
                    Label("Checking your saved data", systemImage: "icloud")
                    Text("If you're signed in, setup waits for cloud sync before offering these steps. You can skip setup and continue using Ledgerly.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if store.cloudSyncError != nil {
                        Button("Retry sync") { store.retryCloudSync() }
                    }
                }
            }
            Section {
                Button(hasIncome && hasBudget ? "Finish setup" : "Continue to Ledgerly") { complete() }
                    .font(.body.weight(.semibold)).frame(minHeight: 44)
                if !hasIncome || !hasBudget {
                    Text("You can return to Getting started in Profile & settings at any time.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Getting started")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(finish != nil)
        .toolbar {
            if finish != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { complete() }
                }
            }
        }
        .sheet(item: $editor) { step in
            Group {
                switch step {
                case .income:
                    EntryEditor(store: store, initialKind: .income)
                case .budget:
                    NavigationStack {
                        BudgetScreen(store: store)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Cancel") { editor = nil }
                                }
                            }
                    }
                }
            }
            .environmentObject(auth)
        }
        .onChange(of: auth.user?.uid) { _, _ in editor = nil }
    }

    private func setupRow(_ title: String, subtitle: String, symbol: String,
                          complete: Bool, step: Step) -> some View {
        Button {
            guard ready, !(step == .income ? hasIncome : hasBudget) else { return }
            editor = step
        } label: {
            HStack(spacing: 12) {
                LedgerIconTile(icon: .init(symbol: complete ? "checkmark" : symbol,
                                           color: complete ? Palette.mint : Palette.cranberry), size: 42)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: complete ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(complete ? Palette.mint : Color.secondary)
            }.padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(!ready || complete)
        .accessibilityValue(complete ? "Completed" : "Optional")
    }

    private func complete() {
        if let finish { finish() } else { dismiss() }
    }
}
