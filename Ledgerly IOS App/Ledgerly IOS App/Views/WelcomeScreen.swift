import SwiftUI
import GoogleSignInSwift

struct WelcomeScreen: View {
    let finish: () -> Void
    let signIn: () -> Void
    let isSigningIn: Bool
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 64)).foregroundStyle(Palette.cranberry)
            Text("Ledgerly").font(.system(size: 42, weight: .bold, design: .rounded))
            Text("A clearer view of your money")
                .font(.title3).foregroundStyle(.secondary)
            Text("Track spending, income and your monthly budget in Sri Lankan rupees.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
            GoogleSignInButton(action: signIn)
                .frame(height: 50)
                .disabled(isSigningIn)
            Text("Sign in to sync your transactions and monthly budget. Existing entries will upload to your first account.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Get started", action: finish)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .controlSize(.large)
        }
        .padding(24)
        .background(Palette.cream)
        .tint(Palette.cranberry)
    }
}
