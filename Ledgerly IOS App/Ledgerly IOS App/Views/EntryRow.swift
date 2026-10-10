import SwiftUI

struct EntryRow: View {
    let entry: LedgerEntry
    var body: some View {
        HStack(spacing: 13) {
            LedgerIconTile(icon: .category(entry.category, kind: entry.kind), size: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.displayTitle)
                    .font(.subheadline.bold())
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Text(entry.category)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                Text("\(entry.kind == .expense ? "−" : "+")\(LKR.string(entry.amount))")
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(entry.kind == .expense ? Palette.coral : Palette.mint)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 58)
        .accessibilityElement(children: .combine)
    }
}
