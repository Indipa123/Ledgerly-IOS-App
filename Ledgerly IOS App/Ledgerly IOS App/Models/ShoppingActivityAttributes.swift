import ActivityKit
import Foundation

nonisolated struct ShoppingActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        var spentText: String
        var remainingText: String
        var isOverCap: Bool
        var itemCount: Int
        var quickAddText: String
    }

    var tripID: String
    var tripName: String
    var capText: String
}
