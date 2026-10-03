import SwiftUI
import Charts

struct InsightsScreen: View {
    @ObservedObject var store: LedgerStore
    private var totals: [(String, Double)] {
        Dictionary(grouping: store.thisMonth.filter { $0.kind == .expense }, by: \.category)
            .map { ($0.key, NSDecimalNumber(decimal: $0.value.reduce(0) { $0 + $1.amount }).doubleValue) }
            .sorted { $0.1 > $1.1 }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Spending by category this month").font(.headline)
                if totals.isEmpty {
                    ContentUnavailableView("No spending to show", systemImage: "chart.bar", description: Text("Add an expense to see your insights."))
                } else {
                    Chart(totals, id: \.0) { item in
                        BarMark(x: .value("Amount", item.1), y: .value("Category", item.0))
                            .foregroundStyle(Palette.cranberry)
                    }
                    .frame(height: max(220, CGFloat(totals.count * 44)))
                    .accessibilityLabel("Spending by category")
                    ForEach(totals, id: \.0) { item in
                        LabeledContent(item.0, value: LKR.string(Decimal(item.1)))
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Insights")
    }
}
