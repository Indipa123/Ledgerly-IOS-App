import SwiftUI

/// Uses the unmodified colour logo supplied with the Google Sign-In SDK.
struct GoogleAccountButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image("GoogleMark").renderingMode(.original)
                    .resizable().scaledToFit().frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text("Continue with Google")
                    .font(.system(.body, design: .default).weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 16)
            .foregroundStyle(colorScheme == .dark
                             ? Color(red: 0.89, green: 0.89, blue: 0.89)
                             : Color(red: 0.12, green: 0.12, blue: 0.12))
            .background(colorScheme == .dark
                        ? Color(red: 0.075, green: 0.075, blue: 0.078) : .white,
                        in: Capsule())
            .overlay {
                Capsule().strokeBorder(colorScheme == .dark
                                       ? Color(red: 0.56, green: 0.57, blue: 0.56)
                                       : Color(red: 0.45, green: 0.47, blue: 0.46), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("auth.google")
    }
}

struct AccountPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Palette.cranberry, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}

struct AccountField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content()
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
    }
}
