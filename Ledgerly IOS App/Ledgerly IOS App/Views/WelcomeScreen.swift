import SwiftUI
import GoogleSignInSwift

struct WelcomeScreen: View {
    @ObservedObject var auth: AuthSession
    @ObservedObject var store: LedgerStore
    let finish: () -> Void
    @State private var showingEmailAuth = false
    @State private var showingFirstSteps = false
    var body: some View {
        NavigationStack {
            welcome
                .navigationDestination(isPresented: $showingFirstSteps) {
                    FirstStepsScreen(store: store, auth: auth, finish: finish)
                }
        }
        .sheet(isPresented: $showingEmailAuth) {
            EmailAuthScreen(auth: auth, onSuccess: {
                showingEmailAuth = false
                showingFirstSteps = true
            })
        }
    }

    private var welcome: some View {
        ScrollView {
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
                GoogleSignInButton(action: { auth.signInWithGoogle(onSuccess: { showingFirstSteps = true }) })
                    .frame(height: 50)
                    .disabled(auth.isBusy)
                Button { showingEmailAuth = true } label: {
                    HStack {
                        Spacer()
                        Text("Continue with email")
                        Spacer()
                    }
                    .frame(minHeight: 44)
                }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .controlSize(.large)
                    .disabled(auth.isBusy)
                Text("Sign in to sync your transactions and budgets. Existing entries will upload to your first account.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Get started") { showingFirstSteps = true }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .controlSize(.large)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
        .tint(Palette.cranberry)
    }
}
