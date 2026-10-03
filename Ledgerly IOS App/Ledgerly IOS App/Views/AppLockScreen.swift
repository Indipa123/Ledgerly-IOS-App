import SwiftUI

struct AppLockScreen: View {
    @ObservedObject var lock: AppLockService

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: lock.methodName == "Face ID" ? "faceid" : "lock.shield.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Palette.cranberry)
                    .accessibilityHidden(true)
                Text("Unlock Ledgerly")
                    .font(.title2.bold())
                Text("\(lock.methodName) keeps your money private")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let message = lock.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Palette.coral)
                        .multilineTextAlignment(.center)
                }
                Button(lock.isAuthenticating ? "Unlocking…" : "Try again") {
                    lock.authenticate()
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.cranberry)
                .disabled(lock.isAuthenticating)
                .padding(.top, 20)
                Text("You can choose Use Passcode in the system prompt.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        }
        .accessibilityAddTraits(.isModal)
    }
}
