import SwiftUI
import FirebaseAuth

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = LedgerStore()
    @StateObject private var auth = AuthSession()
    @StateObject private var lock = AppLockService()
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var showingEditor = false
    @State private var editorKind = EntryKind.expense

    var body: some View {
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
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: lock.appDidBecomeActive()
            case .inactive: lock.appDidBecomeInactive()
            case .background: lock.appDidEnterBackground()
            @unknown default: break
            }
        }
        .tint(Palette.cranberry)
        .sheet(isPresented: $showingEditor) { EntryEditor(store: store, initialKind: editorKind) }
        .sheet(isPresented: Binding(get: { !hasSeenWelcome }, set: { if !$0 { hasSeenWelcome = true } })) {
            WelcomeScreen(finish: { hasSeenWelcome = true }, signIn: {
                auth.signInWithGoogle { hasSeenWelcome = true }
            }, isSigningIn: auth.isBusy)
                .interactiveDismissDisabled()
        }
        .alert("Sign-in error", isPresented: Binding(get: { auth.error != nil }, set: { if !$0 { auth.error = nil } })) {
            Button("OK") { auth.error = nil }
        } message: { Text(auth.error ?? "Please try again.") }
        .alert("Could not save", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "Please try again.") }
    }

    private var mainTabs: some View {
        TabView {
            NavigationStack {
                HomeScreen(store: store, add: present)
            }
            .tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack {
                EntriesScreen(store: store, add: { present(.expense) })
            }
            .tabItem { Label("Transactions", systemImage: "list.bullet") }
            NavigationStack {
                PlacesScreen()
            }
            .tabItem { Label("Places", systemImage: "map.fill") }
            NavigationStack {
                InsightsScreen(store: store)
            }
            .tabItem { Label("Insights", systemImage: "chart.bar.fill") }
        }
        .environmentObject(auth)
        .task { auth.start() }
        .onChange(of: auth.user?.uid) { _, uid in store.setAccount(uid) }
    }

    private func present(_ kind: EntryKind) {
        editorKind = kind
        showingEditor = true
    }
}


#Preview { ContentView() }
