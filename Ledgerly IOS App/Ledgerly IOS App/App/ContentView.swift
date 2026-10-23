import SwiftUI
import FirebaseAuth
import Combine

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var store = LedgerStore()
    @StateObject private var shoppingTrips = ShoppingTripStore()
    @StateObject private var auth = AuthSession()
    @StateObject private var lock = AppLockService()
    @StateObject private var keyboardContext = KeyboardWindowContext()
    @ObservedObject private var placeMonitor = PlaceArrivalMonitor.shared
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var showingEditor = false
    @State private var editorKind = EntryKind.expense
    @State private var editorPlaceID: UUID?
    @State private var showingBudget = false
    @State private var showingReminders = false
    @State private var showingSettings = false
    @State private var showingShopping = false
    @State private var showingReport = false
    @State private var notificationEntry: LedgerEntry?
    @State private var selectedTab = 0
    @State private var needsForegroundRefresh = false
    @State private var tabletColumnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        appContent
        .background {
            KeyboardWindowReader(context: keyboardContext)
                .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .focusedSceneValue(\.ledgerKeyboardActions, keyboardCommandsAvailable
                           ? LedgerKeyboardActions(perform: performKeyboardAction) : nil)
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
                .disabled(auth.pendingAccountDeletion != nil)
            if let request = auth.pendingAccountDeletion {
                NavigationStack {
                    AccountDeletionScreen(auth: auth, store: store, accountID: request.accountID, recovering: true)
                }
                .environmentObject(shoppingTrips)
                .zIndex(1)
            }
            if lock.isObscured {
                AppLockScreen(lock: lock)
                    .zIndex(2)
            }
        }
        .environmentObject(lock)
        .onChange(of: keyboardCommandsAvailable) { _, _ in refreshAutomaticLearning() }
        .onChange(of: selectedTab) { _, _ in
            store.personalLearning.setWorkspaceIdle(false)
            refreshAutomaticLearning()
        }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
            refreshAutomaticLearning()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            refreshAutomaticLearning()
        }
        .onChange(of: auth.pendingAccountDeletion?.accountID) { _, uid in
            guard let uid else { return }
            showingEditor = false
            showingBudget = false
            showingReminders = false
            showingReport = false
            showingShopping = false
            showingSettings = false
            notificationEntry = nil
            store.suspendForAccountDeletion(uid)
        }
        .onAppear {
            refreshAutomaticLearning()
            openPendingNotification()
            refreshPlaceMonitoring()
            placeMonitor.reconcileOpenVisits()
        }
        .onReceive(store.$places) { _ in refreshPlaceMonitoring() }
        .onReceive(store.$entries) { _ in
            // @Published emits before entries changes, so read the new snapshot next turn.
            DispatchQueue.main.async {
                refreshPlaceMonitoring()
                openPendingNotification()
            }
        }
        .onChange(of: auth.user?.uid) { _, _ in
            // LedgerStore switches its account on the same change.
            DispatchQueue.main.async { refreshPlaceMonitoring() }
        }
        .onChange(of: auth.isReady) { _, ready in
            if ready {
                store.setAccount(auth.user?.uid)
                store.enableBudgetWidgets()
                DispatchQueue.main.async {
                    refreshPlaceMonitoring()
                    openPendingNotification()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ledgerlyNotificationDestination)) { _ in
            openPendingNotification()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ledgerlyShoppingTripChanged)) { notification in
            if let source = notification.object as? ShoppingTripStore, source !== shoppingTrips {
                shoppingTrips.reloadFromDisk()
            }
        }
        .onOpenURL { url in
            guard auth.pendingAccountDeletion == nil else { return }
            guard url.scheme == "ledgerly" else { return }
            switch url.host {
            case "shopping":
                if horizontalSizeClass == .regular { selectedTab = 6 }
                else { showingShopping = true }
            case "budget":
                selectedTab = 0
                showingBudget = true
            default: break
            }
        }
        .onChange(of: lock.enabled) { _, _ in store.refreshBudgetWidget() }
        .onChange(of: lock.isObscured) { _, obscured in
            if !obscured { openPendingNotification() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                lock.appDidBecomeActive()
                // Face ID temporarily makes the scene inactive; it is not a background return.
                if needsForegroundRefresh {
                    needsForegroundRefresh = false
                    store.refreshCurrentMonth()
                    shoppingTrips.reloadFromDisk()
                    placeMonitor.reconcileOpenVisits()
                    Task { await placeMonitor.refreshPermissions() }
                }
            case .inactive:
                if store.personalLearning.isTraining { store.personalLearning.cancelTraining() }
                lock.appDidBecomeInactive()
            case .background:
                needsForegroundRefresh = true
                if store.personalLearning.isTraining { store.personalLearning.cancelTraining() }
                lock.appDidEnterBackground()
            @unknown default: break
            }
        }
        .tint(Palette.cranberry)
        .sheet(isPresented: $showingEditor) {
            EntryEditor(store: store, initialKind: editorKind, initialPlaceID: editorPlaceID)
        }
        .sheet(isPresented: $showingBudget) { NavigationStack { BudgetScreen(store: store) } }
        .sheet(isPresented: $showingReminders) { NavigationStack { RemindersScreen(store: store) } }
        .sheet(isPresented: $showingReport) {
            NavigationStack {
                ReportScreen(store: store)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingReport = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingShopping) {
            NavigationStack {
                ShoppingTripScreen(store: store, trips: shoppingTrips)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingShopping = false }
                        }
                    }
            }
        }
        .sheet(item: $notificationEntry) { entry in
            NavigationStack {
                EntryDetail(store: store, entry: entry)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { notificationEntry = nil }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsScreen(store: store, notifications: store.notifications)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingSettings = false }
                        }
                    }
            }
            .environmentObject(auth)
            .environmentObject(lock)
            .environmentObject(shoppingTrips)
        }
        .fullScreenCover(isPresented: Binding(get: { !hasSeenWelcome }, set: { if !$0 { hasSeenWelcome = true } })) {
            WelcomeScreen(auth: auth, store: store, finish: { hasSeenWelcome = true })
                .interactiveDismissDisabled()
        }
    }

    private var mainTabs: some View {
        Group {
            if horizontalSizeClass == .regular {
                tabletNavigation
            } else {
                phoneTabs
            }
        }
        .environmentObject(auth)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = store.syncBannerMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: store.cloudSyncError == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    Text(message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Palette.card)
                .accessibilityElement(children: .combine)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let deleted = store.undoableDeletion {
                HStack(spacing: 14) {
                    Image(systemName: "trash")
                        .accessibilityHidden(true)
                    Text("Deleted \(deleted.displayTitle)")
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Undo") { store.undoDeletion() }
                        .fontWeight(.semibold)
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: 560)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
                .shadow(radius: 8, y: 3)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityElement(children: .contain)
            }
        }
        .task { auth.start() }
        .onChange(of: auth.user?.uid) { _, uid in
            store.setAccount(uid)
            shoppingTrips.setAccount(uid)
        }
    }

    private var phoneTabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "square.grid.2x2.fill", value: 0) {
                tabContent(for: 0)
            }
            Tab("Transactions", systemImage: "list.bullet.rectangle.fill", value: 1) {
                tabContent(for: 1)
            }
            Tab("Places", systemImage: "map.fill", value: 2) {
                tabContent(for: 2)
            }
            Tab("Insights", systemImage: "chart.bar.xaxis", value: 3) {
                tabContent(for: 3)
            }
        }
    }

    private var tabletNavigation: some View {
        NavigationSplitView(columnVisibility: $tabletColumnVisibility) {
            List(selection: Binding<Int?>(
                get: { selectedTab },
                set: { if let destination = $0 { selectedTab = destination } }
            )) {
                Section {
                    NavigationLink(value: 0) {
                        Label("Home", systemImage: "square.grid.2x2.fill")
                    }
                    NavigationLink(value: 1) {
                        Label("Transactions", systemImage: "list.bullet.rectangle.fill")
                    }
                    NavigationLink(value: 2) {
                        Label("Places", systemImage: "map.fill")
                    }
                    NavigationLink(value: 3) {
                        Label("Insights", systemImage: "chart.bar.xaxis")
                    }
                    NavigationLink(value: 4) {
                        Label("Event budgets", systemImage: "calendar.badge.clock")
                    }
                    NavigationLink(value: 5) {
                        Label("Split with friends", systemImage: "person.2.fill")
                    }
                    NavigationLink(value: 6) {
                        Label("Shopping trip", systemImage: "basket.fill")
                    }
                } header: {
                    Text("Workspace")
                }
            }
            .navigationTitle("Ledgerly")
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(
                min: dynamicTypeSize.isAccessibilitySize ? 320 : 220,
                ideal: dynamicTypeSize.isAccessibilitySize ? 360 : 250,
                max: dynamicTypeSize.isAccessibilitySize ? 420 : 290
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }
                .background(.regularMaterial)
            }
        } detail: {
            tabContent(for: selectedTab)
        }
    }

    @ViewBuilder
    private func tabContent(for tab: Int) -> some View {
        if tab == 1 {
            // Entries owns its list/detail stacks so wide iPad layouts can show both.
            EntriesScreen(store: store, add: { present(.expense) },
                          allowsColumns: horizontalSizeClass == .regular)
                .id(auth.user?.uid ?? "guest")
        } else if tab == 2 {
            PlacesScreen(store: store, monitor: placeMonitor, recordExpense: presentExpense,
                         allowsColumns: horizontalSizeClass == .regular)
                .id(auth.user?.uid ?? "guest")
        } else {
          NavigationStack {
            switch tab {
            case 3:
                InsightsScreen(store: store)
            case 4:
                LifeEventsScreen(store: store)
            case 5:
                SplitsScreen(store: store)
            case 6:
                ShoppingTripScreen(store: store, trips: shoppingTrips)
            default:
                HomeScreen(store: store, shoppingTrips: shoppingTrips, add: present)
            }
          }
        }
    }

    private func present(_ kind: EntryKind) {
        editorKind = kind
        editorPlaceID = nil
        showingEditor = true
    }

    private func refreshAutomaticLearning() {
        store.personalLearning.setWorkspaceIdle(keyboardCommandsAvailable && keyboardContext.canOpenWorkspace,
            availability: { [weak context = keyboardContext] in context?.canOpenWorkspace == true })
    }

    private var keyboardCommandsAvailable: Bool {
        hasSeenWelcome && auth.isReady && !auth.isBusy && !lock.isObscured && !lock.isLocked &&
        auth.pendingAccountDeletion == nil &&
        scenePhase == .active && !showingEditor && !showingBudget && !showingReminders &&
        !showingSettings && !showingShopping && !showingReport && notificationEntry == nil &&
        auth.error == nil && store.error == nil
    }

    private func performKeyboardAction(_ action: LedgerKeyboardAction) {
        guard keyboardCommandsAvailable, keyboardContext.canOpenWorkspace else { return }
        switch action {
        case .expense: present(.expense)
        case .income: present(.income)
        case .budget: showingBudget = true
        case .report: showingReport = true
        case .home: selectedTab = 0
        case .transactions: selectedTab = 1
        case .places: selectedTab = 2
        case .insights: selectedTab = 3
        case .settings: showingSettings = true
        }
    }

    private func presentExpense(at place: LedgerPlace) {
        editorKind = .expense
        editorPlaceID = place.id
        placeMonitor.dismissArrival(for: place.id)
        showingEditor = true
    }

    private func refreshPlaceMonitoring() {
        guard auth.isReady else { return }
        placeMonitor.configure(places: store.places, entries: store.entries, owner: auth.user?.uid)
    }

    private func openPendingNotification() {
        guard !lock.isObscured, auth.pendingAccountDeletion == nil,
              let destination = UserDefaults.standard.string(forKey: "ledgerly.pendingNotificationDestination") else { return }
        if destination.hasPrefix("transaction:") {
            guard auth.isReady else { return }
            selectedTab = 1
            let rawID = String(destination.dropFirst("transaction:".count))
            guard let id = UUID(uuidString: rawID),
                  let entry = store.entries.first(where: { $0.id == id }) else { return }
            UserDefaults.standard.removeObject(forKey: "ledgerly.pendingNotificationDestination")
            notificationEntry = entry
            return
        }
        UserDefaults.standard.removeObject(forKey: "ledgerly.pendingNotificationDestination")
        switch destination {
        case "budget": showingBudget = true
        case "addExpense": present(.expense)
        case "places": selectedTab = 2
        case "shoppingTrip":
            shoppingTrips.reloadFromDisk()
            if horizontalSizeClass == .regular { selectedTab = 6 }
            else { showingShopping = true }
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
