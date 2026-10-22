import Foundation
import LocalAuthentication
import Testing
@testable import LedgerlyDomain

@Suite("App lock authentication lifecycle")
@MainActor
struct AppLockServiceTests {
    private func makeLock() -> (AppLockService, TestLockAuthentication) {
        let defaults = UserDefaults(suiteName: "Ledgerly.AppLockTests.\(UUID())")!
        defaults.set(true, forKey: "ledgerly.appLock.enabled")
        defaults.set(0, forKey: "ledgerly.appLock.graceSeconds")
        let authentication = TestLockAuthentication()
        return (AppLockService(defaults: defaults, authentication: authentication), authentication)
    }

    @Test func coldLaunchAuthenticatesWhenActiveAndUnlocksImmediately() {
        let (lock, authentication) = makeLock()
        lock.appDidBecomeActive()
        #expect(lock.isLocked && lock.isObscured && lock.isAuthenticating)
        #expect(authentication.attempts == 1)
        authentication.complete(true)
        #expect(!lock.isLocked && !lock.isObscured && !lock.isAuthenticating)
        #expect(lock.message == nil)
    }

    @Test func successfulPromptRevealsHomeAndRemovesCoverTogether() {
        let (lock, authentication) = makeLock()
        lock.appDidBecomeActive()
        lock.appDidBecomeInactive()
        authentication.complete(true)
        #expect(lock.isLocked && lock.isObscured && lock.isAuthenticating)
        lock.appDidBecomeActive()
        #expect(!lock.isLocked && !lock.isObscured && !lock.isAuthenticating)
        #expect(authentication.attempts == 1)
    }

    @Test func activeBeforeCallbackDoesNotStartAnotherPrompt() {
        let (lock, authentication) = makeLock()
        lock.appDidBecomeActive()
        lock.appDidBecomeInactive()
        lock.appDidBecomeActive()
        #expect(authentication.attempts == 1)
        authentication.complete(true)
        #expect(!lock.isLocked && !lock.isObscured)
    }

    @Test func lateInactiveEventStillProtectsTheAppSwitcher() {
        let (lock, authentication) = makeLock()
        lock.appDidBecomeActive()
        authentication.complete(true)
        lock.appDidBecomeInactive()
        #expect(!lock.isLocked && lock.isObscured)
        lock.appDidBecomeActive()
        #expect(!lock.isLocked && !lock.isObscured)
        #expect(authentication.attempts == 1)
    }

    @Test func failedAuthenticationNeverRevealsMoney() {
        let (lock, authentication) = makeLock()
        lock.appDidBecomeActive()
        authentication.complete(false, error: LAError(.authenticationFailed))
        #expect(lock.isLocked && lock.isObscured && !lock.isAuthenticating)
        #expect(lock.message != nil)
        lock.authenticate()
        #expect(authentication.attempts == 2)
    }

    @Test func cancelledPromptDoesNotImmediatelyPromptAgain() {
        let (lock, authentication) = makeLock()
        lock.appDidBecomeActive()
        lock.appDidBecomeInactive()
        authentication.complete(false, error: LAError(.userCancel))
        lock.appDidBecomeActive()
        #expect(authentication.attempts == 1)
        #expect(lock.isLocked && lock.isObscured && !lock.isAuthenticating)
    }

    @Test func backgroundCancelsPromptAndIgnoresLateSuccess() {
        let (lock, authentication) = makeLock()
        lock.appDidBecomeActive()
        lock.appDidEnterBackground()
        #expect(authentication.cancellations == 1)
        authentication.complete(true)
        #expect(lock.isLocked && lock.isObscured)
        lock.appDidBecomeActive()
        #expect(authentication.attempts == 2)
        authentication.complete(true)
        #expect(!lock.isLocked && !lock.isObscured)
    }

    @Test func backgroundingAfterSuccessDoesNotRevealHomeOnReturn() {
        let (lock, authentication) = makeLock()
        lock.appDidBecomeActive()
        lock.appDidBecomeInactive()
        authentication.complete(true)
        lock.appDidEnterBackground()
        #expect(lock.isLocked && lock.isObscured && !lock.isAuthenticating)
        lock.appDidBecomeActive()
        #expect(lock.isLocked && lock.isObscured && lock.isAuthenticating)
        #expect(authentication.attempts == 2)
    }

    @Test func expiredBackgroundGraceRequiresAnotherAuthentication() {
        let (lock, authentication) = makeLock()
        lock.appDidBecomeActive()
        authentication.complete(true)
        lock.appDidBecomeInactive()
        #expect(lock.isObscured)
        lock.appDidEnterBackground()
        lock.appDidBecomeActive()
        #expect(lock.isLocked && lock.isObscured)
        #expect(authentication.attempts == 2)
    }

    @Test func disablingInvalidatesPendingAuthentication() {
        let (lock, authentication) = makeLock()
        lock.appDidBecomeActive()
        lock.disable()
        authentication.complete(false, error: LAError(.authenticationFailed))
        #expect(!lock.enabled && !lock.isLocked && !lock.isObscured)
        #expect(lock.message == nil)
    }
}

@MainActor
private final class TestLockAuthentication: AppLockAuthenticating {
    let methodName = "Face ID"
    var availabilityMessage: String?
    private(set) var attempts = 0
    private(set) var cancellations = 0
    private var completion: (@MainActor (Bool, Error?) -> Void)?

    func evaluate(reason: String, completion: @escaping @MainActor (Bool, Error?) -> Void) {
        attempts += 1
        self.completion = completion
    }

    func cancel() { cancellations += 1 }

    func complete(_ success: Bool, error: Error? = nil) {
        let callback = completion
        completion = nil
        callback?(success, error)
    }
}
