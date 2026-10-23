import SwiftUI
import FirebaseAuth

struct SettingsScreen: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var notifications: LedgerNotificationService
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var lock: AppLockService
    @AppStorage("appearance") private var appearance = 0
    @State private var showingEmailAuth = false
    @State private var confirmingSignOut = false
    @State private var signOutAccountID: String?

    var body: some View {
        Form {
            Section {
                if let user = auth.user {
                    VStack(spacing: 0) {
                        AccountProfileHeader(accountID: user.uid, name: auth.profileName,
                                             email: user.email, photoURL: auth.profilePhotoURL,
                                             provider: auth.signInMethod)
                        NavigationLink { ProfileScreen(auth: auth) } label: {
                            Label("Edit profile", systemImage: "pencil")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.iconPlum)
                        .disabled(auth.isBusy)
                    }
                } else {
                    VStack(spacing: 16) {
                        AccountProfileHeader(accountID: nil, name: "Welcome to Ledgerly",
                                             email: "Keep your money organised, wherever you go.",
                                             photoURL: nil, provider: "Guest · saved on this device")
                        GoogleAccountButton { auth.signInWithGoogle() }
                        Button("Continue with email") { showingEmailAuth = true }
                            .font(.body.weight(.semibold)).frame(minHeight: 44)
                    }
                    .disabled(auth.isBusy)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))

            if auth.user != nil {
                Section("Account") {
                    NavigationLink { AccountSecurityScreen(auth: auth, store: store) } label: {
                        SettingsMenuRow(title: "Account security", subtitle: "Sign-in, email and password",
                                        symbol: "lock.shield.fill")
                    }
                    .disabled(auth.isBusy)
                    NavigationLink { CloudSyncSettingsScreen(store: store) } label: {
                        SettingsMenuRow(title: "Data and sync", subtitle: store.syncStatus,
                                        symbol: "icloud.fill", color: Palette.mint)
                    }
                }
            }

            Section("Money management") {
                NavigationLink { CategoriesScreen(store: store) } label: {
                    SettingsMenuRow(title: "Categories", subtitle: "Organise income and expenses",
                                    symbol: "square.grid.2x2.fill", color: Palette.cranberry)
                }
                NavigationLink { PaymentMethodsScreen(store: store) } label: {
                    SettingsMenuRow(title: "Payment methods", subtitle: "Cash, cards and bank transfers",
                                    symbol: "creditcard.fill")
                }
                NavigationLink { LearnedCategoriesScreen(store: store) } label: {
                    SettingsMenuRow(title: "Learned categories", subtitle: "Review your saved choices",
                                    symbol: "sparkle.magnifyingglass")
                }
                NavigationLink { RemindersScreen(store: store) } label: {
                    SettingsMenuRow(title: "Payment reminders", subtitle: "Upcoming payments and schedules",
                                    symbol: "calendar.badge.clock", color: Palette.coral)
                }
            }

            Section("Preferences") {
                NavigationLink { AppearanceSettingsScreen() } label: {
                    SettingsMenuRow(title: "Appearance", subtitle: appearanceName,
                                    symbol: "circle.lefthalf.filled")
                }
                NavigationLink { NotificationSettingsScreen(notifications: notifications) } label: {
                    SettingsMenuRow(title: "Notifications", subtitle: "Budget alerts and notification access",
                                    symbol: "bell.fill", color: Palette.coral)
                }
                NavigationLink { AppLockSettingsScreen() } label: {
                    SettingsMenuRow(title: "App lock", subtitle: lock.enabled ? "Enabled · \(lock.methodName)" : "Protect access to Ledgerly",
                                    symbol: "lock.fill")
                }
                NavigationLink { WidgetSettingsScreen(store: store) } label: {
                    SettingsMenuRow(title: "Home Screen widgets", subtitle: "Your monthly budget at a glance",
                                    symbol: "rectangle.grid.1x2.fill", color: Palette.mint)
                }
            }

            Section("Privacy and information") {
                NavigationLink { FirstStepsScreen(store: store, auth: auth) } label: {
                    SettingsMenuRow(title: "Getting started", subtitle: "First income and monthly budget",
                                    symbol: "sparkles", color: Palette.cranberry)
                }
                NavigationLink { PermissionsScreen() } label: {
                    SettingsMenuRow(title: "Permissions", subtitle: "Location, camera and device access",
                                    symbol: "hand.raised.fill")
                }
                NavigationLink { PrivacySettingsScreen() } label: {
                    SettingsMenuRow(title: "Your data", subtitle: "What stays on this device and what syncs",
                                    symbol: "externaldrive.fill")
                }
                LabeledContent("Currency", value: "LKR · Sri Lankan rupee")
                DisclosureGroup("Help and shortcuts") {
                    NavigationLink { KeyboardShortcutsScreen() } label: {
                        Label("Keyboard shortcuts", systemImage: "keyboard")
                    }
                }
            }

            if let user = auth.user {
                Section {
                    Button(role: .destructive) {
                        signOutAccountID = user.uid
                        confirmingSignOut = true
                    } label: {
                        SettingsMenuRow(title: "Sign out", subtitle: "Review sync before leaving your account",
                                        symbol: "rectangle.portrait.and.arrow.right", color: .red, titleColor: .red)
                    }
                    .disabled(auth.isBusy)
                    .accessibilityIdentifier("settings.signOut")
                }
            }

            Section {
                Text(versionLabel)
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
            }
            .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.cream)
        .navigationTitle("Profile & settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingEmailAuth) {
            EmailAuthScreen(auth: auth, onSuccess: { showingEmailAuth = false })
        }
        .sheet(isPresented: $confirmingSignOut) {
            if let uid = signOutAccountID {
                NavigationStack {
                    SignOutReviewScreen(store: store, auth: auth, accountID: uid)
                }
            }
        }
        .onChange(of: auth.user?.uid) { _, _ in
            confirmingSignOut = false
            signOutAccountID = nil
            showingEmailAuth = false
        }
    }

    private var appearanceName: String {
        switch appearance {
        case 1: "Light"
        case 2: "Dark"
        default: "Follow device theme"
        }
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Ledgerly · Version \(version) (\(build))"
    }
}
