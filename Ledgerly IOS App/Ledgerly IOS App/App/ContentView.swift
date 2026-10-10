import SwiftUI
import FirebaseAuth

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = LedgerStore()
    @StateObject private var auth = AuthSession()
    @StateObject private var lock = AppLockService()
    @ObservedObject private var placeMonitor = PlaceArrivalMonitor.shared
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var showingEditor = false
    @State private var editorKind = EntryKind.expense
    @State private var editorPlaceID: UUID?
    @State private var showingBudget = false
    @State private var showingReminders = false
    @State private var selectedTab = 0

    var body: some View {
        appContent
        .alert("Sign-in error", isPresented: Binding(get: { auth.error != nil }, set: { if !$0 { auth.error = nil } })) {
            Button("OK") { auth.error = nil }
        } message: { Text(auth.error ?? "Please try again.") }
        .alert("Could not save", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "Please try again.") }
    }

    private var appContent: some View {
        ZStack {
            mainTabs
            if lock.isObscured {
                AppLockScreen(lock: lock)
                    .zIndex(1)
                    .transition(.opacity)
            }
        }
        .environmentObject(lock)
        .onAppear {
            if lock.isLocked { lock.authenticate() }
            openPendingNotification()
            refreshPlaceMonitoring()
            placeMonitor.reconcileOpenVisits()
        }
        .onReceive(store.$places) { _ in refreshPlaceMonitoring() }
        .onReceive(store.$entries) { _ in refreshPlaceMonitoring() }
        .onChange(of: auth.user?.uid) { _, _ in
            // LedgerStore switches its account on the same change.
            DispatchQueue.main.async { refreshPlaceMonitoring() }
        }
        .onChange(of: auth.isReady) { _, ready in
            if ready { DispatchQueue.main.async { refreshPlaceMonitoring() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ledgerlyNotificationDestination)) { _ in
            openPendingNotification()
        }
        .onChange(of: lock.isObscured) { _, obscured in
            if !obscured { openPendingNotification() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                lock.appDidBecomeActive()
                placeMonitor.reconcileOpenVisits()
                Task { await placeMonitor.refreshPermissions() }
            case .inactive: lock.appDidBecomeInactive()
            case .background: lock.appDidEnterBackground()
            @unknown default: break
            }
        }
        .tint(Palette.cranberry)
        .sheet(isPresented: $showingEditor) {
            EntryEditor(store: store, initialKind: editorKind, initialPlaceID: editorPlaceID)
        }
        .sheet(isPresented: $showingBudget) { NavigationStack { BudgetScreen(store: store) } }
        .sheet(isPresented: $showingReminders) { NavigationStack { RemindersScreen(store: store) } }
        .sheet(isPresented: Binding(get: { !hasSeenWelcome }, set: { if !$0 { hasSeenWelcome = true } })) {
            WelcomeScreen(finish: { hasSeenWelcome = true }, signIn: {
                auth.signInWithGoogle { hasSeenWelcome = true }
            }, isSigningIn: auth.isBusy)
                .interactiveDismissDisabled()
        }
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeScreen(store: store, add: present)
            }
            .tabItem { Label("Home", systemImage: "square.grid.2x2.fill") }
            .tag(0)
            NavigationStack {
                EntriesScreen(store: store, add: { present(.expense) })
            }
            .tabItem { Label("Transactions", systemImage: "list.bullet.rectangle.fill") }
            .tag(1)
            NavigationStack {
                PlacesScreen(store: store, monitor: placeMonitor, recordExpense: presentExpense)
            }
            .tabItem { Label("Places", systemImage: "map.fill") }
            .tag(2)
            NavigationStack {
                InsightsScreen(store: store)
            }
            .tabItem { Label("Insights", systemImage: "chart.bar.xaxis") }
            .tag(3)
        }
        .environmentObject(auth)
        .task { auth.start() }
        .onChange(of: auth.user?.uid) { _, uid in store.setAccount(uid) }
    }

    private func present(_ kind: EntryKind) {
        editorKind = kind
        editorPlaceID = nil
        showingEditor = true
    }

    private func presentExpense(at place: LedgerPlace) {
        editorKind = .expense
        editorPlaceID = place.id
        placeMonitor.dismissArrival()
        showingEditor = true
    }

    private func refreshPlaceMonitoring() {
        guard auth.isReady else { return }
        placeMonitor.configure(places: store.places, entries: store.entries, owner: auth.user?.uid)
    }

    private func openPendingNotification() {
        guard !lock.isObscured,
              let destination = UserDefaults.standard.string(forKey: "ledgerly.pendingNotificationDestination") else { return }
        UserDefaults.standard.removeObject(forKey: "ledgerly.pendingNotificationDestination")
        switch destination {
        case "budget": showingBudget = true
        case "addExpense": present(.expense)
        case "places": selectedTab = 2
        case let place where place.hasPrefix("placeExpense:"):
            let rawID = String(place.dropFirst("placeExpense:".count))
            if let id = UUID(uuidString: rawID), let saved = store.places.first(where: { $0.id == id }) {
                presentExpense(at: saved)
            } else { present(.expense) }
        default: showingReminders = true
        }
    }
}


#Preview { ContentView() }
