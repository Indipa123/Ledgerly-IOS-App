import SwiftUI

struct HomeScreen: View {
    @ObservedObject var store: LedgerStore
    let add: (EntryKind) -> Void
    @AppStorage("dashboardAllTime") private var allTime = false

    private var current: [LedgerEntry] { allTime ? store.entries : store.thisMonth }
    private var income: Decimal { current.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount } }
    private var expense: Decimal { current.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount } }
    private var left: Decimal { store.budget - store.spentSoFar }
    private var usedRatio: Double {
        store.budget > 0 ? min(1, NSDecimalNumber(decimal: store.spentSoFar / store.budget).doubleValue) : 0
    }
    private var daysLeft: Int {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: .now) else { return 1 }
        return max(1, range.count - calendar.component(.day, from: .now) + 1)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
                if store.budget == 0 {
                    NavigationLink { BudgetScreen(store: store) } label: {
                        Label("Set your monthly budget", systemImage: "target")
                            .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding()
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                addCard
                recentCard
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(Palette.cream.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                NavigationLink { SettingsScreen(store: store) } label: {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title2).foregroundStyle(.white)
                }
                .accessibilityLabel("Profile and settings")
                Text("Your money at a glance").font(.subheadline.bold()).foregroundStyle(.white)
                Spacer()
                Picker("Period", selection: $allTime) {
                    Text("Month").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.menu)
                .tint(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR \(Date.now.formatted(.dateTime.month(.wide)).uppercased()) BUDGET")
                    .font(.caption.bold()).tracking(1).foregroundStyle(.white.opacity(0.8))
                Text(store.budget > 0 ? LKR.string(max(0, left)) : "Set a budget")
                    .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.65).lineLimit(1).foregroundStyle(.white)
                Text(store.budget == 0 ? "plan your month in seconds" : left < 0 ? "over budget" : "still yours to spend")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85))
            }
            if store.budget > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(LKR.string(store.spentSoFar)) used of \(LKR.string(store.budget))")
                        .font(.caption).foregroundStyle(.white.opacity(0.9))
                    ProgressView(value: usedRatio)
                        .tint(Color(red: 0.77, green: 0.95, blue: 0.49))
                    if left < 0 {
                        Label("Over budget by \(LKR.string(-left))", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.bold()).foregroundStyle(.white)
                    }
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "arrow.up.right")
                    .font(.headline.bold()).foregroundStyle(Palette.mint)
                    .frame(width: 42, height: 42)
                    .background(Palette.mint.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("YOUR DAILY PACE").font(.caption2.bold()).foregroundStyle(.secondary)
                    Text(store.budget > 0 ? LKR.string(max(0, left) / Decimal(daysLeft)) : "Add a budget")
                        .font(.title3.bold().monospacedDigit()).foregroundStyle(Palette.ink)
                    Text(store.budget > 0 ? "per day · \(daysLeft) \(daysLeft == 1 ? "day" : "days") left" : "to see your daily pace")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
            HStack {
                metric("INCOME", value: income, color: Color(red: 0.47, green: 0.95, blue: 0.85))
                Divider().overlay(.white.opacity(0.4))
                metric("SPENT", value: expense, color: .white)
            }
            .padding(14)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
        }
        .padding(18)
        .background(LinearGradient(colors: [Palette.cranberry, Palette.plum], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 28))
        .accessibilityElement(children: .contain)
    }

    private func metric(_ title: String, value: Decimal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.bold()).foregroundStyle(.white.opacity(0.8))
            Text(LKR.string(value)).font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("ADD TRANSACTIONS").font(.caption2.bold()).foregroundStyle(.secondary)
            Text("Log expense or income").font(.headline).foregroundStyle(Palette.ink)
            Text("Capture money movement so budgets stay accurate")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { add(.expense) } label: {
                    Label("Expenses", systemImage: "minus.circle.fill")
                        .frame(maxWidth: .infinity).frame(minHeight: 44)
                }
                .buttonStyle(.bordered).tint(Palette.coral)
                Button { add(.income) } label: {
                    Label("Income", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity).frame(minHeight: 44)
                }
                .buttonStyle(.bordered).tint(Palette.mint)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent transactions").font(.headline).foregroundStyle(Palette.ink)
            if store.entries.isEmpty {
                ContentUnavailableView("No transactions yet", systemImage: "tray", description: Text("Add an expense or income to get started."))
            } else {
                ForEach(store.entries.prefix(4)) { entry in
                    NavigationLink { EntryDetail(store: store, entry: entry) } label: {
                        EntryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
    }
}
