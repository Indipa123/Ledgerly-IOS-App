import Foundation
import Combine

extension Notification.Name {
    static let ledgerlyShoppingTripChanged = Notification.Name("ledgerly.shoppingTripChanged")
}

@MainActor
final class ShoppingTripStore: ObservableObject {
    @Published private(set) var activeTrip: ShoppingTrip?
    @Published var error: String?
    private var accountID: String?

    init(accountID: String? = nil) {
        self.accountID = accountID
        load()
    }

    func setAccount(_ uid: String?) {
        guard uid != accountID else { return }
        if let uid, !FileManager.default.fileExists(atPath: Self.url(for: uid).path),
           let guest = activeTrip, accountID == nil,
           UserDefaults.standard.string(forKey: "ledgerly.guestClaimedBy") == nil ||
           UserDefaults.standard.string(forKey: "ledgerly.guestClaimedBy") == uid {
            // Carry an unfinished guest trip into the same account as guest transactions.
            do {
                try Self.write(guest, to: Self.url(for: uid))
                try? FileManager.default.removeItem(at: Self.url(for: nil))
            } catch { self.error = error.localizedDescription }
        }
        accountID = uid
        if let uid { UserDefaults.standard.set(uid, forKey: "ledgerly.shoppingOwner") }
        else { UserDefaults.standard.removeObject(forKey: "ledgerly.shoppingOwner") }
        load()
    }

    func reloadFromDisk() { load() }

    func eraseForAccountDeletion(_ uid: String, includesClaimedGuest: Bool) throws {
        for file in includesClaimedGuest ? [Self.url(for: uid), Self.url(for: nil)] : [Self.url(for: uid)] {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        if accountID == uid {
            activeTrip = nil
            ShoppingActivityManager.schedule(nil)
        }
        if UserDefaults.standard.string(forKey: "ledgerly.shoppingOwner") == uid {
            UserDefaults.standard.removeObject(forKey: "ledgerly.shoppingOwner")
        }
    }

    @discardableResult
    func start(name: String, cap: Decimal, categoryID: UUID, eventID: UUID?,
               location: LedgerLocation? = nil) -> Bool {
        guard activeTrip == nil else { error = "Finish or discard the current trip first."; return false }
        let trip = ShoppingTrip(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                cap: cap, categoryID: categoryID, eventID: eventID,
                                startedAt: .now, items: [], location: location)
        guard trip.isValid else { error = "Enter a trip name and a positive spending cap."; return false }
        return persist(trip)
    }

    @discardableResult
    func addItem(name: String, unitPrice: Decimal, quantity: Int) -> Bool {
        guard var trip = activeTrip else { return false }
        let item = ShoppingItem(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                unitPrice: unitPrice, quantity: quantity)
        guard item.isValid else { error = "Enter an item name, positive price, and quantity."; return false }
        trip.items.append(item)
        return persist(trip)
    }

    func removeItem(id: UUID) {
        guard var trip = activeTrip else { return }
        trip.items.removeAll { $0.id == id }
        _ = persist(trip)
    }

    @discardableResult
    func updateItem(_ item: ShoppingItem) -> Bool {
        guard item.isValid, var trip = activeTrip,
              let index = trip.items.firstIndex(where: { $0.id == item.id }) else {
            error = "Enter an item name, positive price, and quantity."
            return false
        }
        trip.items[index] = item
        return persist(trip)
    }

    func changeCategory(_ id: UUID) {
        guard var trip = activeTrip else { return }
        trip.categoryID = id
        _ = persist(trip)
    }

    func changeEvent(_ id: UUID?) {
        guard var trip = activeTrip else { return }
        trip.eventID = id
        _ = persist(trip)
    }

    func changeLocation(_ location: LedgerLocation?) {
        guard var trip = activeTrip else { return }
        trip.location = location
        _ = persist(trip)
    }

    func changeQuickAddAmount(_ amount: Int) {
        guard (50...100_000).contains(amount), var trip = activeTrip else { return }
        trip.quickAddAmount = amount
        _ = persist(trip)
    }

    func discard() {
        do {
            let file = Self.url(for: accountID)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            activeTrip = nil
            ShoppingActivityManager.schedule(nil)
            NotificationCenter.default.post(name: .ledgerlyShoppingTripChanged, object: self)
        } catch { self.error = error.localizedDescription }
    }

    // Only clear the draft after LedgerStore has saved its grouped expense.
    func finish() { discard() }

    private func persist(_ trip: ShoppingTrip) -> Bool {
        guard !AccountDeletionJournal.shared.blocks(owner: accountID) else { return false }
        do {
            try Self.write(trip, to: Self.url(for: accountID))
            activeTrip = trip
            ShoppingActivityManager.schedule(trip)
            NotificationCenter.default.post(name: .ledgerlyShoppingTripChanged, object: self)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func load() {
        if AccountDeletionJournal.shared.blocks(owner: accountID) {
            activeTrip = nil
            ShoppingActivityManager.schedule(nil)
            return
        }
        do {
            let file = Self.url(for: accountID)
            activeTrip = FileManager.default.fileExists(atPath: file.path)
                ? try JSONDecoder().decode(ShoppingTrip.self, from: Data(contentsOf: file)) : nil
            ShoppingActivityManager.schedule(activeTrip)
        } catch {
            activeTrip = nil
            self.error = "Could not open the saved shopping trip: \(error.localizedDescription)"
        }
    }

    private static func url(for accountID: String?) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let key = accountID.map { Data($0.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-") } ?? "guest"
        return folder.appendingPathComponent("Ledgerly-shopping-\(key).json")
    }

    private static func write(_ trip: ShoppingTrip, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(trip).write(to: url, options: .atomic)
    }
}
