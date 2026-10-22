import SwiftUI
import WidgetKit

struct MonthlyBudgetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: BudgetWidgetStorage.kind, provider: BudgetWidgetProvider()) { entry in
            BudgetWidgetView(entry: entry)
        }
        .configurationDisplayName("Monthly budget")
        .description("Your spending, monthly limit, and remaining budget at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct BudgetWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: BudgetWidgetSnapshot?
}

private struct BudgetWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BudgetWidgetEntry { sample() }

    func getSnapshot(in context: Context, completion: @escaping (BudgetWidgetEntry) -> Void) {
        completion(context.isPreview ? sample() : .init(date: .now, snapshot: BudgetWidgetStorage.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BudgetWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = BudgetWidgetStorage.read()
        let next = snapshot?.nextUpdate(after: now) ?? now.addingTimeInterval(60 * 60)
        completion(Timeline(entries: [.init(date: now, snapshot: snapshot),
                                      .init(date: next, snapshot: snapshot)], policy: .after(next)))
    }

    private func sample() -> BudgetWidgetEntry {
        let now = Date()
        return .init(date: now, snapshot: .init(budget: 35_000,
            expenses: [.init(date: now, amount: 12_450)], asOf: now))
    }
}

private struct BudgetWidgetView: View {
    let entry: BudgetWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    private let cranberry = Color(red: 0.73, green: 0.08, blue: 0.31)
    private var secondary: Color { colorScheme == .dark ? .white.opacity(0.72) : .black.opacity(0.6) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "chart.pie.fill").foregroundStyle(cranberry)
                Text("Ledgerly").fontWeight(.semibold)
                Spacer(minLength: 0)
                if family == .systemMedium {
                    Text(entry.date, format: .dateTime.month(.wide)).foregroundStyle(secondary)
                }
            }
            .font(.caption)
            if let snapshot = entry.snapshot {
                if snapshot.amountsHidden {
                    message("Budget hidden", detail: family == .systemSmall ? "App Lock is on\nTap to open" :
                        "App Lock is on. Open Ledgerly to view.", symbol: "lock.fill")
                } else if !snapshot.isCurrent(at: entry.date) {
                    message("A fresh month", detail: "Open Ledgerly to refresh", symbol: "calendar")
                } else {
                    budgetContent(snapshot)
                }
            } else {
                message("Your monthly budget", detail: "Open Ledgerly to get started", symbol: "wallet.bifold.fill")
            }
        }
        .foregroundStyle(colorScheme == .dark ? Color.white : Color(red: 0.17, green: 0.08, blue: 0.14))
        .containerBackground(for: .widget) {
            LinearGradient(colors: colorScheme == .dark
                ? [Color(red: 0.20, green: 0.08, blue: 0.17), Color(red: 0.10, green: 0.07, blue: 0.11)]
                : [Color(red: 1, green: 0.94, blue: 0.96), .white],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .widgetURL(URL(string: "ledgerly://budget"))
    }

    @ViewBuilder
    private func budgetContent(_ snapshot: BudgetWidgetSnapshot) -> some View {
        let spent = snapshot.spent(at: entry.date)
        let remaining = snapshot.remaining(at: entry.date)
        if snapshot.budget > 0 {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(remaining < 0 ? "OVER BUDGET" : "LEFT THIS MONTH")
                        .font(.caption2.weight(.semibold)).foregroundStyle(secondary)
                    amount(abs(remaining), font: .title2.bold())
                        .foregroundStyle(remaining < 0 ? cranberry : (colorScheme == .dark ? .white : .primary))
                }
                if family == .systemMedium {
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("MONTHLY LIMIT").font(.caption2.weight(.semibold)).foregroundStyle(secondary)
                        amount(snapshot.budget, font: .subheadline.weight(.semibold))
                    }
                }
            }
            Spacer(minLength: 0)
            ProgressView(value: snapshot.fractionUsed(at: entry.date))
                .tint(cranberry)
                .accessibilityLabel("Budget used")
                .accessibilityValue("\(Int(snapshot.fractionUsed(at: entry.date) * 100)) percent")
            HStack(spacing: 4) {
                Text("Spent").foregroundStyle(secondary)
                amount(spent, font: .caption.weight(.medium))
            }
            .font(.caption)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text("Set a budget").font(.title3.bold())
                Text("Plan this month in Ledgerly").font(.caption).foregroundStyle(secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text("Spent").foregroundStyle(secondary)
                amount(spent, font: .caption.weight(.medium))
            }
            .font(.caption)
        }
    }

    private func amount(_ amount: Decimal, font: Font) -> some View {
        Text(amount.formatted(.currency(code: "LKR").locale(Locale(identifier: "en_LK"))))
            .font(font).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            .privacySensitive()
    }

    private func message(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: symbol).font(.title3).foregroundStyle(cranberry)
            Text(title).font(.headline).lineLimit(2).minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.caption).foregroundStyle(secondary).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

#Preview("Small", as: .systemSmall) { MonthlyBudgetWidget() } timeline: {
    BudgetWidgetEntry(date: .now, snapshot: .init(budget: 35_000,
        expenses: [.init(date: .now.addingTimeInterval(-1), amount: 12_450)]))
}

#Preview("Medium", as: .systemMedium) { MonthlyBudgetWidget() } timeline: {
    BudgetWidgetEntry(date: .now, snapshot: .init(budget: 35_000,
        expenses: [.init(date: .now.addingTimeInterval(-1), amount: 12_450)]))
}
