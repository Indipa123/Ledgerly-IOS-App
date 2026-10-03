import Foundation

enum AppLockTiming {
    static func shouldRelock(backgroundedAt: Date, now: Date, graceSeconds: TimeInterval) -> Bool {
        return now.timeIntervalSince(backgroundedAt) >= graceSeconds
    }
}
