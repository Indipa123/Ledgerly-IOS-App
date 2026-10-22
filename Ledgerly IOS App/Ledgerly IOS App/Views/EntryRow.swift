import SwiftUI

struct EntryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: LedgerEntry

    private var usesStackedAmounts: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            LedgerIconTile(icon: .category(entry.category, kind: entry.kind), size: 48)
                .accessibilityHidden(true)
            let layout = usesStackedAmounts
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.displayTitle)
                        .font(.subheadline.bold())
                        .foregroundStyle(Palette.ink)
                        .lineLimit(usesStackedAmounts ? nil : 2)
                    Text(entry.category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(usesStackedAmounts ? nil : 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: usesStackedAmounts ? .leading : .trailing, spacing: 5) {
                    Text("\(entry.kind == .expense ? "−" : "+")\(LKR.string(entry.amount))")
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(entry.kind == .expense ? Palette.coral : Palette.mint)
                        .lineLimit(usesStackedAmounts ? nil : 1)
                        .minimumScaleFactor(usesStackedAmounts ? 1 : 0.7)
                    Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 58)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.displayTitle), \(entry.kind.label), \(entry.category)")
        .accessibilityValue("\(LKR.string(entry.amount)), \(entry.date.formatted(date: .complete, time: .omitted))")
    }
}
