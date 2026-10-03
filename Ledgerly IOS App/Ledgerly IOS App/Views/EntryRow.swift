import SwiftUI

struct EntryRow: View {
    let entry: LedgerEntry
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind == .expense ? "arrow.up.right" : "arrow.down.left")
                .foregroundStyle(entry.kind == .expense ? Palette.coral : Palette.mint)
                .frame(width: 38, height: 38)
                .background((entry.kind == .expense ? Palette.coral : Palette.mint).opacity(0.12), in: Circle())
            VStack(alignment: .leading) {
                Text(entry.displayTitle).font(.subheadline.bold()).foregroundStyle(Palette.ink)
                Text("\(entry.category) · \(entry.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(entry.kind == .expense ? "−" : "+") \(LKR.string(entry.amount))")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(entry.kind == .expense ? Palette.coral : Palette.mint)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(minHeight: 50)
        .accessibilityElement(children: .combine)
    }
}
