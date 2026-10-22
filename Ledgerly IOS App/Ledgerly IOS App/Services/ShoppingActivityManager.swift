import ActivityKit
import Foundation

@MainActor
enum ShoppingActivityManager {
    private static var pending: Task<Void, Never>?

    static func schedule(_ trip: ShoppingTrip?) {
        let previous = pending
        pending = Task {
            await previous?.value
            await reconcile(trip)
        }
    }

    private static func reconcile(_ trip: ShoppingTrip?) async {
        let activities = Activity<ShoppingActivityAttributes>.activities
        for activity in activities where activity.attributes.tripID != trip?.id.uuidString {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        guard let trip, ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let state = ShoppingActivityAttributes.ContentState(
            spentText: LKR.string(trip.spent),
            remainingText: LKR.string(abs(trip.remaining)),
            isOverCap: trip.remaining < 0,
            itemCount: trip.items.count,
            quickAddText: LKR.string(Decimal(trip.quickAddValue))
        )
        let content = ActivityContent(state: state,
                                      staleDate: Date.now.addingTimeInterval(8 * 60 * 60))
        if let existing = Activity<ShoppingActivityAttributes>.activities.first(where: {
            $0.attributes.tripID == trip.id.uuidString
        }) {
            await existing.update(content)
        } else {
            let attributes = ShoppingActivityAttributes(tripID: trip.id.uuidString,
                                                         tripName: trip.name,
                                                         capText: LKR.string(trip.cap))
            _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
        }
    }
}
