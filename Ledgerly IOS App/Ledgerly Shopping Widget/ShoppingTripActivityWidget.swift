import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct LedgerlyShoppingWidgets: WidgetBundle {
    var body: some Widget {
        MonthlyBudgetWidget()
        ShoppingTripActivityWidget()
    }
}

private struct ShoppingTripActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShoppingActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(context.attributes.tripName, systemImage: "basket.fill")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text("\(context.state.itemCount) items")
                        .font(.caption)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.isOverCap ? "OVER CAP" : "REMAINING")
                            .font(.caption2.bold())
                        Text(context.state.remainingText)
                            .font(.title2.bold().monospacedDigit())
                            .foregroundStyle(context.state.isOverCap ? .orange : .white)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("SPENT").font(.caption2.bold())
                        Text(context.state.spentText).font(.subheadline.monospacedDigit())
                    }
                }
                Button(intent: QuickAddShoppingItemIntent(tripID: context.attributes.tripID)) {
                    Label("Add \(context.state.quickAddText) item", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
            }
            .padding(16)
            .foregroundStyle(.white)
            .background(Color(red: 0.19, green: 0.08, blue: 0.17))
            .widgetURL(URL(string: "ledgerly://shopping"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.tripName, systemImage: "basket.fill")
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.isOverCap ? "Over cap" : "Remaining")
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.remainingText)
                            .font(.headline.monospacedDigit())
                        Spacer()
                        Button(intent: QuickAddShoppingItemIntent(tripID: context.attributes.tripID)) {
                            Label("Add \(context.state.quickAddText)", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } compactLeading: {
                Image(systemName: "basket.fill")
            } compactTrailing: {
                Text(context.state.remainingText).font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "basket.fill")
            }
            .widgetURL(URL(string: "ledgerly://shopping"))
        }
    }
}
