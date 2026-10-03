import Foundation
import Testing
@testable import LedgerlyDomain

@Suite("App lock grace period")
struct AppLockTimingTests {
    @Test func immediatelyLocksOnReturn() {
        let backgroundedAt = Date(timeIntervalSince1970: 1_000)
        #expect(AppLockTiming.shouldRelock(backgroundedAt: backgroundedAt,
                                          now: backgroundedAt, graceSeconds: 0))
    }

    @Test func waitsUntilGracePeriodEnds() {
        let backgroundedAt = Date(timeIntervalSince1970: 1_000)
        #expect(!AppLockTiming.shouldRelock(backgroundedAt: backgroundedAt,
                                           now: backgroundedAt.addingTimeInterval(14.9),
                                           graceSeconds: 15))
        #expect(AppLockTiming.shouldRelock(backgroundedAt: backgroundedAt,
                                          now: backgroundedAt.addingTimeInterval(15),
                                          graceSeconds: 15))
    }
}
