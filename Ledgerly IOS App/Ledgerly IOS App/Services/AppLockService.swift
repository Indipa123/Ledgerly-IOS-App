import Combine
import Foundation
import LocalAuthentication

@MainActor
final class AppLockService: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var isLocked: Bool
    @Published private(set) var isObscured: Bool
    @Published private(set) var isAuthenticating = false
    @Published var message: String?
    @Published var graceSeconds: Double {
        didSet { defaults.set(graceSeconds, forKey: Self.graceKey) }
    }

    private static let enabledKey = "ledgerly.appLock.enabled"
    private static let graceKey = "ledgerly.appLock.graceSeconds"
    private let defaults: UserDefaults
    private var backgroundedAt: Date?
    private var authenticationGeneration = 0
    private var isActive = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedEnabled = defaults.bool(forKey: Self.enabledKey)
        enabled = storedEnabled
        isLocked = storedEnabled
        isObscured = storedEnabled
        graceSeconds = defaults.object(forKey: Self.graceKey) as? Double ?? 15
    }

    var methodName: String {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "device passcode"
        }
    }

    var availabilityMessage: String? {
        let context = LAContext()
        var error: NSError?
        guard !context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return nil }
        if error?.code == LAError.passcodeNotSet.rawValue {
            return "Set a device passcode in iPhone Settings before enabling app lock."
        }
        return "Device authentication is unavailable right now."
    }

    func enable() {
        guard !enabled, !isAuthenticating else { return }
        guard availabilityMessage == nil else {
            message = availabilityMessage
            return
        }
        evaluate(reason: "Confirm your identity to lock Ledgerly") { [weak self] in
            guard let self else { return }
            self.enabled = true
            self.defaults.set(true, forKey: Self.enabledKey)
            self.isLocked = false
            self.isObscured = !self.isActive
        }
    }

    func disable() {
        authenticationGeneration += 1
        enabled = false
        defaults.set(false, forKey: Self.enabledKey)
        isLocked = false
        isObscured = false
        isAuthenticating = false
        backgroundedAt = nil
        message = nil
    }

    func lockNow() {
        guard enabled else { return }
        isLocked = true
        isObscured = true
        authenticate()
    }

    func appDidBecomeInactive() {
        isActive = false
        if enabled { isObscured = true }
    }

    func appDidEnterBackground() {
        isActive = false
        guard enabled else { return }
        backgroundedAt = .now
        isObscured = true
    }

    func appDidBecomeActive() {
        isActive = true
        guard enabled else { return }
        let shouldRelock = backgroundedAt.map {
            AppLockTiming.shouldRelock(backgroundedAt: $0, now: .now, graceSeconds: graceSeconds)
        } ?? false
        if shouldRelock {
            isLocked = true
        }
        backgroundedAt = nil
        isObscured = isLocked
        if shouldRelock { authenticate() }
    }

    func authenticate() {
        guard enabled, isLocked, !isAuthenticating else { return }
        guard availabilityMessage == nil else {
            message = availabilityMessage
            return
        }
        evaluate(reason: "Unlock Ledgerly to view your money") { [weak self] in
            guard let self else { return }
            self.isLocked = false
            self.isObscured = !self.isActive
            self.backgroundedAt = nil
        }
    }

    private func evaluate(reason: String, onSuccess: @escaping @MainActor () -> Void) {
        authenticationGeneration += 1
        let generation = authenticationGeneration
        isAuthenticating = true
        message = nil
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, error in
            guard let self else { return }
            Task { @MainActor in
                guard generation == self.authenticationGeneration else { return }
                self.isAuthenticating = false
                if success {
                    onSuccess()
                } else if let error = error as? LAError,
                          error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
                    self.message = nil
                } else {
                    self.message = "Could not unlock. Try again or use your device passcode."
                }
            }
        }
    }
}
