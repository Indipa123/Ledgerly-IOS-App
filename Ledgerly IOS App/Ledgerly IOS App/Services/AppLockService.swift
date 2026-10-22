import Combine
import Foundation
import LocalAuthentication

@MainActor
protocol AppLockAuthenticating: AnyObject {
    var methodName: String { get }
    var availabilityMessage: String? { get }
    func evaluate(reason: String, completion: @escaping @MainActor (Bool, Error?) -> Void)
    func cancel()
}

@MainActor
private final class DeviceAppLockAuthentication: AppLockAuthenticating {
    let methodName: String
    private var context: LAContext?

    init() {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: methodName = "Face ID"
        case .touchID: methodName = "Touch ID"
        default: methodName = "device passcode"
        }
    }

    var availabilityMessage: String? {
        let context = LAContext()
        var error: NSError?
        guard !context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return nil }
        if error?.code == LAError.passcodeNotSet.rawValue {
            return "Set a passcode in device Settings before enabling app lock."
        }
        return "Device authentication is unavailable right now."
    }

    func evaluate(reason: String, completion: @escaping @MainActor (Bool, Error?) -> Void) {
        let context = LAContext()
        self.context = context
        context.localizedFallbackTitle = "Use Passcode"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            Task { @MainActor in completion(success, error) }
        }
    }

    func cancel() {
        context?.invalidate()
        context = nil
    }
}

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
    private let authentication: any AppLockAuthenticating
    private let defaults: UserDefaults
    private var backgroundedAt: Date?
    private var authenticationGeneration = 0
    private var isActive = false
    private var hasActivated = false
    private var unlockAwaitingActivation = false

    init(defaults: UserDefaults = .standard, authentication: (any AppLockAuthenticating)? = nil) {
        self.authentication = authentication ?? DeviceAppLockAuthentication()
        self.defaults = defaults
        let storedEnabled = defaults.bool(forKey: Self.enabledKey)
        enabled = storedEnabled
        isLocked = storedEnabled
        isObscured = storedEnabled
        graceSeconds = defaults.object(forKey: Self.graceKey) as? Double ?? 15
    }

    var methodName: String { authentication.methodName }
    var availabilityMessage: String? { authentication.availabilityMessage }

    func enable() {
        guard !enabled, !isAuthenticating else { return }
        if let unavailable = availabilityMessage {
            message = unavailable
            return
        }
        evaluate(reason: "Confirm your identity to lock Ledgerly") { [weak self] in
            guard let self else { return }
            self.enabled = true
            self.defaults.set(true, forKey: Self.enabledKey)
            self.finishUnlock()
        }
    }

    func disable() {
        authenticationGeneration += 1
        authentication.cancel()
        unlockAwaitingActivation = false
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
        unlockAwaitingActivation = false
        if isAuthenticating {
            authenticationGeneration += 1
            authentication.cancel()
            isAuthenticating = false
        }
        guard enabled else { return }
        backgroundedAt = .now
        isObscured = true
    }

    func appDidBecomeActive() {
        let isFirstActivation = !hasActivated
        hasActivated = true
        isActive = true
        guard enabled else { return }
        if unlockAwaitingActivation {
            finishUnlock()
            isAuthenticating = false
            return
        }
        let shouldRelock = backgroundedAt.map {
            AppLockTiming.shouldRelock(backgroundedAt: $0, now: .now, graceSeconds: graceSeconds)
        } ?? false
        if shouldRelock {
            isLocked = true
        }
        backgroundedAt = nil
        isObscured = isLocked
        if shouldRelock || isFirstActivation { authenticate() }
    }

    func authenticate() {
        guard enabled, isLocked, !isAuthenticating else { return }
        if let unavailable = availabilityMessage {
            message = unavailable
            return
        }
        evaluate(reason: "Unlock Ledgerly to view your money") { [weak self] in
            guard let self else { return }
            self.finishUnlock()
        }
    }

    private func finishUnlock() {
        backgroundedAt = nil
        if isActive {
            unlockAwaitingActivation = false
            isLocked = false
            isObscured = false
        } else {
            // Face ID can finish before its system prompt returns the scene to active.
            // Keep the existing lock view until Home and its privacy cover can change together.
            unlockAwaitingActivation = true
            isLocked = true
            isObscured = true
        }
    }

    private func evaluate(reason: String, onSuccess: @escaping @MainActor () -> Void) {
        authenticationGeneration += 1
        let generation = authenticationGeneration
        isAuthenticating = true
        message = nil
        authentication.evaluate(reason: reason) { [weak self] success, error in
            guard let self, generation == self.authenticationGeneration else { return }
            if success {
                // Apply the unlock before resetting the button's progress state.
                onSuccess()
                self.message = nil
            } else if let error = error as? LAError,
                      error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
                self.message = nil
            } else {
                self.message = "Could not unlock. Try again or use your device passcode."
            }
            self.isAuthenticating = self.unlockAwaitingActivation
        }
    }
}
