import SwiftUI

/// A single navigation target with a live preview and a clearly labelled action.
struct DashboardActionCard<Destination: View, Preview: View>: View {
    let title: String
    let symbol: String
    let accent: Color
    let action: String
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let preview: () -> Preview

    var body: some View {
        NavigationLink(destination: destination) {
            VStack(alignment: .leading, spacing: 14) {
                LedgerIconTile(icon: .init(symbol: symbol, color: accent), size: 42)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                preview()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Text(action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .padding(.top, 8)
                    .overlay(alignment: .top) { Rectangle().fill(accent.opacity(0.18)).frame(height: 1) }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Palette.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(DashboardCardPressStyle())
        .accessibilityElement(children: .combine)
        .hoverEffect(.highlight)
    }
}

struct DashboardEntryButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(accent.opacity(configuration.isPressed ? 0.24 : 0.12),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(accent.opacity(0.25), lineWidth: 1)
            }
    }
}

private struct DashboardCardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct DashboardProgressRing: View {
    let value: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: 6)
            Circle().trim(from: 0, to: min(1, max(0, value)))
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: value >= 1 ? "exclamationmark" : "chart.pie.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(color)
        }
        .frame(width: 42, height: 42)
        .accessibilityHidden(true)
    }
}
