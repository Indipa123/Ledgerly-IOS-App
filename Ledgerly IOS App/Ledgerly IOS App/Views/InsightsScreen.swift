import SwiftUI
import Charts

struct InsightsScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var store: LedgerStore

    private var categories: [InsightAmount] { InsightCalculations.categoryTotals(store.entries) }
    private var payments: [InsightAmount] {
        InsightCalculations.paymentTotals(store.entries, methods: store.paymentMethods)
    }
    private var cards: [InsightAmount] {
        InsightCalculations.cardTotals(store.entries, methods: store.paymentMethods)
    }
    private var months: [InsightMonth] { InsightCalculations.monthlyTotals(store.entries) }
    private var days: [InsightDay] { InsightCalculations.dailyExpenses(store.entries) }
    private var donut: [InsightAmount] {
        guard categories.count > 6 else { return categories }
        return Array(categories.prefix(5)) + [
            InsightAmount(name: "Other categories", amount: categories.dropFirst(5).reduce(0) { $0 + $1.amount })
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Your money, clearly").font(.title2.bold())
                Text("Spending through today. Future transactions are left out of these charts.")
                    .font(.footnote).foregroundStyle(.secondary)
                if dynamicTypeSize.isAccessibilitySize {
                    stackedSections
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            VStack(spacing: 18) {
                                categorySection
                                monthlySection
                            }
                            .frame(maxWidth: .infinity)
                            VStack(spacing: 18) {
                                dailySection
                                paymentSection
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .frame(minWidth: 860)
                        stackedSections
                    }
                }
            }
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
            .padding(18)
        }
        .background(Palette.cream.ignoresSafeArea())
        .navigationTitle("Insights")
        .toolbar {
            NavigationLink {
                ReportScreen(store: store)
            } label: {
                Label("Report", systemImage: "doc.text")
            }
        }
    }

    private var stackedSections: some View {
        VStack(spacing: 18) {
            categorySection
            monthlySection
            dailySection
            paymentSection
        }
    }

    private var categorySection: some View {
        section("Spending by category", subtitle: "This month", icon: "chart.pie.fill") {
            if categories.isEmpty {
                empty("No spending this month", symbol: "chart.pie")
            } else {
                Chart(donut) { item in
                    SectorMark(angle: .value("Spending", item.chartAmount),
                               innerRadius: .ratio(0.58), angularInset: 2)
                        .foregroundStyle(LedgerIconDescriptor.category(item.name, kind: .expense).color)
                }
                .frame(height: 245)
                .accessibilityHidden(true)
                ForEach(categories) { item in
                    NavigationLink {
                        CategoryInsightDetail(store: store, categoryName: item.name)
                    } label: {
                        drilldownRow(item.name, amount: item.amount,
                                     icon: .category(item.name, kind: .expense))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows this month's expenses in \(item.name)")
                }
            }
        }
    }

    private var monthlySection: some View {
        section("Income and expenses", subtitle: "Last six months", icon: "chart.bar.fill") {
            if months.allSatisfy({ $0.income == 0 && $0.expense == 0 }) {
                empty("No income or expenses yet", symbol: "chart.bar")
            } else {
                Chart {
                    ForEach(months) { month in
                        BarMark(x: .value("Month", month.start, unit: .month),
                                y: .value("Amount", double(month.income)))
                            .foregroundStyle(by: .value("Type", "Income"))
                            .position(by: .value("Type", "Income"))
                        BarMark(x: .value("Month", month.start, unit: .month),
                                y: .value("Amount", double(month.expense)))
                            .foregroundStyle(by: .value("Type", "Spent"))
                            .position(by: .value("Type", "Spent"))
                    }
                }
                .frame(height: 230)
                .accessibilityHidden(true)
                ForEach(months) { month in
                    HStack(spacing: 10) {
                        LedgerIconTile(icon: .init(symbol: "calendar", color: Palette.iconPlum), size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(month.start.formatted(.dateTime.month(.wide).year())).font(.subheadline.bold())
                            Text("Income \(LKR.string(month.income)) · Spent \(LKR.string(month.expense))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var dailySection: some View {
        section("Daily spending", subtitle: "Last 30 days", icon: "chart.xyaxis.line") {
            if days.allSatisfy({ $0.expense == 0 }) {
                empty("No spending in the last 30 days", symbol: "chart.xyaxis.line")
            } else {
                Chart(days) { day in
                    LineMark(x: .value("Day", day.date, unit: .day),
                             y: .value("Spent", double(day.expense)))
                        .foregroundStyle(Palette.cranberry)
                    PointMark(x: .value("Day", day.date, unit: .day),
                              y: .value("Spent", double(day.expense)))
                        .foregroundStyle(Palette.cranberry)
                }
                .frame(height: 210)
                .accessibilityHidden(true)
                moneyRow("Total over 30 days", amount: days.reduce(0) { $0 + $1.expense },
                         icon: .init(symbol: "sum", color: Palette.cranberry))
                DisclosureGroup("Daily totals") {
                    ForEach(days) { day in
                        moneyRow(day.date.formatted(date: .abbreviated, time: .omitted), amount: day.expense,
                                 icon: .init(symbol: "calendar", color: Palette.iconPlum))
                    }
                }
            }
        }
    }

    private var paymentSection: some View {
        section("Payment methods", subtitle: "This month", icon: "creditcard.fill") {
            if payments.isEmpty {
                empty("No spending by payment method yet", symbol: "creditcard")
            } else {
                Chart(payments) { item in
                    BarMark(x: .value("Amount", item.chartAmount),
                            y: .value("Method", item.name))
                        .foregroundStyle(Palette.cranberry)
                }
                .frame(height: max(170, CGFloat(payments.count * 42)))
                .accessibilityHidden(true)
                ForEach(payments) { item in
                    let method = store.paymentMethods.first { $0.name == item.name }
                    NavigationLink {
                        PaymentInsightDetail(store: store, paymentName: item.name, cardsOnly: false)
                    } label: {
                        drilldownRow(item.name, amount: item.amount,
                                     icon: method.map { .payment($0.kind) } ??
                                        .init(symbol: "creditcard.fill", color: Palette.iconPlum))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows this month's expenses paid with \(item.name)")
                }
                if !cards.isEmpty {
                    Divider()
                    Text("Card spending").font(.subheadline.bold())
                    ForEach(cards) { item in
                        NavigationLink {
                            PaymentInsightDetail(store: store, paymentName: item.name, cardsOnly: true)
                        } label: {
                            drilldownRow(item.name, amount: item.amount,
                                         icon: .init(symbol: "creditcard.fill", color: Palette.iconPlum))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows this month's card expenses for \(item.name)")
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, subtitle: String, icon: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                LedgerIconTile(icon: .init(symbol: icon, color: Palette.cranberry), size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(Palette.ink)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func moneyRow(_ title: String, amount: Decimal,
                          icon: LedgerIconDescriptor) -> some View {
        HStack(alignment: .top, spacing: 10) {
            LedgerIconTile(icon: icon, size: 34)
                .accessibilityHidden(true)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
            layout {
                Text(title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text(LKR.string(amount))
                    .font(.subheadline.bold().monospacedDigit())
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.75)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(LKR.string(amount))
    }

    private func drilldownRow(_ title: String, amount: Decimal,
                              icon: LedgerIconDescriptor) -> some View {
        HStack(spacing: 8) {
            moneyRow(title, amount: amount, icon: icon)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
    }

    private func empty(_ title: String, symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol,
                               description: Text("Add transactions to see this insight."))
            .frame(maxWidth: .infinity)
    }

    private func double(_ amount: Decimal) -> Double {
        NSDecimalNumber(decimal: amount).doubleValue
    }
}

private struct CategoryInsightDetail: View {
    @ObservedObject var store: LedgerStore
    let categoryName: String

    private var transactions: [LedgerEntry] {
        InsightCalculations.categoryEntries(store.entries, category: categoryName)
    }

    private var total: Decimal {
        transactions.reduce(0) { $0 + $1.amount }
    }

    private var limit: CategoryBudget? {
        let key = CategoryBudget.key(monthKey: CategoryBudget.monthKey(for: .now),
                                     categoryName: categoryName)
        return store.categoryBudgets.first { $0.id == key }
    }

    var body: some View {
        List {
            Section("This month") {
                LabeledContent("Spent", value: LKR.string(total))
                LabeledContent("Transactions", value: transactions.count.formatted())
                if let limit, limit.amount > 0 {
                    LabeledContent("Category limit", value: LKR.string(limit.amount))
                    let remaining = limit.amount - total
                    let usage = NSDecimalNumber(decimal: total / limit.amount).doubleValue
                    LabeledContent(remaining < 0 ? "Over limit" : "Remaining",
                                   value: LKR.string(abs(remaining)))
                    ProgressView(value: min(1, usage))
                        .tint(remaining < 0 ? Palette.cranberry : Palette.iconPlum)
                        .accessibilityLabel("Category limit used")
                        .accessibilityValue("\((usage * 100).formatted(.number.precision(.fractionLength(0)))) percent")
                } else {
                    LabeledContent("Category limit", value: "None set")
                }
            }
            Section("Expenses") {
                if transactions.isEmpty {
                    ContentUnavailableView("No expenses this month", systemImage: "tray",
                                           description: Text("Expenses you add in this category will appear here."))
                } else {
                    ForEach(transactions) { entry in
                        NavigationLink {
                            EntryDetail(store: store, entry: entry)
                        } label: {
                            EntryRow(entry: entry)
                        }
                    }
                }
            }
        }
        .navigationTitle(categoryName)
    }
}

private struct PaymentInsightDetail: View {
    @ObservedObject var store: LedgerStore
    let paymentName: String
    let cardsOnly: Bool

    private var transactions: [LedgerEntry] {
        InsightCalculations.paymentEntries(store.entries, methods: store.paymentMethods,
                                           name: paymentName, cardsOnly: cardsOnly)
    }

    private var method: LedgerPaymentMethod? {
        store.paymentMethods.first {
            $0.name == paymentName &&
            (!cardsOnly || $0.kind == .debitCard || $0.kind == .creditCard)
        }
    }

    private var includesMissingMethod: Bool {
        let knownIDs = Set(store.paymentMethods.map(\.id))
        return transactions.contains { $0.paymentMethodID.map { !knownIDs.contains($0) } ?? true }
    }

    var body: some View {
        List {
            Section("This month") {
                LabeledContent("Spent", value: LKR.string(transactions.reduce(0) { $0 + $1.amount }))
                LabeledContent("Transactions", value: transactions.count.formatted())
                if let method {
                    LabeledContent("Type", value: method.kind.label)
                    if let lastFour = method.lastFour {
                        LabeledContent("Card ending", value: lastFour)
                    }
                }
                if includesMissingMethod {
                    Text("Includes expenses with no available payment method.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Expenses") {
                if transactions.isEmpty {
                    ContentUnavailableView("No expenses this month", systemImage: "tray",
                                           description: Text("Expenses for this payment method will appear here."))
                } else {
                    ForEach(transactions) { entry in
                        NavigationLink {
                            EntryDetail(store: store, entry: entry)
                        } label: {
                            EntryRow(entry: entry)
                        }
                    }
                }
            }
        }
        .navigationTitle(paymentName)
    }
}
