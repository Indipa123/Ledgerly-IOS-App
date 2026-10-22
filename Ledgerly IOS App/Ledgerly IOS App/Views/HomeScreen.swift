import SwiftUI
import Charts
import FirebaseAuth

struct HomeScreen: View {
    @EnvironmentObject private var auth: AuthSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var store: LedgerStore
    @ObservedObject var shoppingTrips: ShoppingTripStore
    let add: (EntryKind) -> Void
    @AppStorage("dashboardAllTime") private var allTime = false
    @ScaledMetric(relativeTo: .largeTitle) private var balanceSize: CGFloat = 38

    private var current: [LedgerEntry] { allTime ? store.entries : store.thisMonth }
    private var income: Decimal { current.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount } }
    private var expense: Decimal { current.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount } }
    private var left: Decimal { store.budget - store.spentSoFar }
    private var usedRatio: Double {
        store.budget > 0 ? min(1, NSDecimalNumber(decimal: store.spentSoFar / store.budget).doubleValue) : 0
    }
    private var daysLeft: Int {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: .now) else { return 1 }
        return max(1, range.count - calendar.component(.day, from: .now) + 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = horizontalSizeClass == .regular && geometry.size.width >= 900 &&
                !dynamicTypeSize.isAccessibilitySize
            let contentWidth = min(1180, max(0, geometry.size.width -
                (horizontalSizeClass == .regular ? 56 : 36)))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if horizontalSizeClass == .regular {
                        Text(Date.now.formatted(.dateTime.month(.wide).year()))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if wide {
                        HStack(alignment: .top, spacing: 18) {
                            VStack(spacing: 18) {
                                hero
                                weeklySpendingCard
                            }
                            .frame(maxWidth: .infinity)
                            VStack(spacing: 18) {
                                planningCards(width: (contentWidth - 18) / 2)
                                addCard
                                recentCard
                                categorySnapshotCard
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 14) {
                            hero
                            planningCards(width: contentWidth)
                            addCard
                            recentCard
                        }
                    }
                    if horizontalSizeClass == .regular && !wide {
                        VStack(spacing: 18) {
                            weeklySpendingCard
                            categorySnapshotCard
                        }
                    }
                }
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 18)
                .padding(.top, horizontalSizeClass == .regular ? 4 : 0)
                .padding(.bottom, 24)
            }
        }
        .background(Palette.cream.ignoresSafeArea())
        .navigationTitle("Overview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(homeNavigationBarVisibility, for: .navigationBar)
    }

    private var homeNavigationBarVisibility: Visibility {
        if #available(iOS 26, *) { return .visible }
        return horizontalSizeClass == .regular ? .visible : .hidden
    }

    private var weeklySpendingCard: some View {
        let days = InsightCalculations.dailyExpenses(store.entries, days: 7)
        return VStack(alignment: .leading, spacing: 14) {
            Label("Last 7 days", systemImage: "chart.bar.fill")
                .font(.headline).foregroundStyle(Palette.ink)
            Text("Spending by day").font(.subheadline).foregroundStyle(.secondary)
            if days.allSatisfy({ $0.expense == 0 }) {
                ContentUnavailableView("No recent spending", systemImage: "chart.bar",
                                       description: Text("Your daily activity will appear here."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Chart(days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day),
                            y: .value("Spent", NSDecimalNumber(decimal: day.expense).doubleValue))
                        .foregroundStyle(Palette.cranberry.gradient)
                        .cornerRadius(5)
                }
                .frame(height: 180)
                .accessibilityLabel("Daily spending over the last seven days")
            }
        }
        .dashboardCard()
    }

    private var categorySnapshotCard: some View {
        let categories = InsightCalculations.categoryTotals(store.entries)
        let total = categories.reduce(Decimal.zero) { $0 + $1.amount }
        return VStack(alignment: .leading, spacing: 14) {
            Label("Where it went", systemImage: "chart.pie.fill")
                .font(.headline).foregroundStyle(Palette.ink)
            Text("Top categories this month").font(.subheadline).foregroundStyle(.secondary)
            if categories.isEmpty {
                ContentUnavailableView("No spending this month", systemImage: "chart.pie",
                                       description: Text("Categories will appear as you add expenses."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ForEach(categories.prefix(3)) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(category.name).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(LKR.string(category.amount)).monospacedDigit().lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .font(.subheadline)
                        ProgressView(value: NSDecimalNumber(decimal: category.amount / total).doubleValue)
                            .tint(LedgerIconDescriptor.category(category.name, kind: .expense).color)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .dashboardCard()
    }

    private func planningCards(width: CGFloat) -> some View {
        let twoColumns = !dynamicTypeSize.isAccessibilitySize &&
            (width >= 520 || (width >= 360 && dynamicTypeSize <= .large))
        let columns = Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
                            count: twoColumns ? 2 : 1)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Plan & manage").font(.title3.bold()).foregroundStyle(Palette.ink)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                budgetCard
                eventsCard
                splitsCard
                shoppingTripCard
            }
        }
    }

    private var budgetCard: some View {
        DashboardActionCard(title: "Monthly budget", symbol: "slider.horizontal.3",
                            accent: Palette.dashboardAccent,
                            action: store.budget > 0 ? "Adjust budget" : "Set a budget") {
            BudgetScreen(store: store)
        } preview: {
            VStack(alignment: .leading, spacing: 10) {
                if store.budget > 0 {
                    HStack(spacing: 12) {
                        DashboardProgressRing(value: usedRatio, color: Palette.dashboardAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((NSDecimalNumber(decimal: store.spentSoFar / store.budget).doubleValue)
                                .formatted(.percent.precision(.fractionLength(0))))
                                .font(.title3.bold().monospacedDigit())
                            Text("used").font(.subheadline).foregroundStyle(Palette.dashboardSecondary)
                        }
                    }
                    Text("\(LKR.string(store.budget)) limit")
                        .font(.subheadline).foregroundStyle(Palette.dashboardSecondary)
                    if left < 0 {
                        Label("Over budget", systemImage: "exclamationmark.circle")
                            .font(.subheadline.weight(.medium)).foregroundStyle(Palette.dashboardAccent)
                    }
                } else {
                    Text("Set your spending limit").font(.title3.bold())
                    Text("Choose a monthly limit to stay on track.")
                        .font(.subheadline).foregroundStyle(Palette.dashboardSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("home.monthlyBudget")
    }

    private var eventsCard: some View {
        let active = store.lifeEvents.filter { $0.completedAt == nil }
        let current = active.filter { $0.endDate >= Calendar.current.startOfDay(for: .now) }
            .sorted { $0.startDate == $1.startDate ? $0.id.uuidString < $1.id.uuidString : $0.startDate < $1.startDate }
        let featured = current.first ?? active.sorted { $0.endDate > $1.endDate }.first
        return DashboardActionCard(title: "Event budgets", symbol: featured?.kind.symbol ?? "calendar.badge.clock",
                                   accent: Palette.iconPlum, action: featured == nil ? "Plan an event" : "View events") {
            LifeEventsScreen(store: store)
        } preview: {
            VStack(alignment: .leading, spacing: 10) {
                if let event = featured {
                    let spent = event.spent(in: store.entries)
                    Text(event.name).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                    Text(event.endDate < Calendar.current.startOfDay(for: .now) ? "Ready to review" :
                         event.startDate > .now ? "Starts \(event.startDate.formatted(.dateTime.day().month(.abbreviated)))" :
                         "Ends \(event.endDate.formatted(.dateTime.day().month(.abbreviated)))")
                        .font(.subheadline).foregroundStyle(Palette.dashboardSecondary)
                    ProgressView(value: event.budget > 0 ?
                        min(1, max(0, NSDecimalNumber(decimal: spent / event.budget).doubleValue)) : 0)
                        .tint(Palette.iconPlum)
                        .accessibilityLabel("Event budget used")
                    Text("\(LKR.string(spent)) of \(LKR.string(event.budget))")
                        .font(.subheadline).foregroundStyle(Palette.dashboardSecondary)
                } else {
                    Text("No active events").font(.title3.bold())
                    Text("Plan a trip or celebration.")
                        .font(.subheadline).foregroundStyle(Palette.dashboardSecondary)
                }
            }
        }
        .accessibilityIdentifier("home.eventBudgets")
    }

    private var splitsCard: some View {
        let bills = store.splitBills.filter { $0.deletedAt == nil }
        let owed = bills.reduce(Decimal.zero) { $0 + $1.outstanding }
        let friendIDs = Set(bills.flatMap(\.shares).filter {
            $0.friendID != nil && $0.settledAt == nil && $0.amount > 0
        }.compactMap(\.friendID))
        let friends = store.friends.filter { friendIDs.contains($0.id) }
            .sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name }
        return DashboardActionCard(title: "Split with friends", symbol: "person.2.fill",
                                   accent: Palette.dashboardAccent,
                                   action: bills.isEmpty ? "Create a split" : "View balances") {
            SplitsScreen(store: store)
        } preview: {
            VStack(alignment: .leading, spacing: 10) {
                if owed > 0 {
                    Text(LKR.string(owed)).font(.title3.bold().monospacedDigit())
                        .fixedSize(horizontal: false, vertical: true)
                    Text("owed to you").font(.subheadline).foregroundStyle(Palette.dashboardSecondary)
                    HStack(spacing: 8) {
                        HStack(spacing: -8) {
                            ForEach(Array(friends.prefix(3))) { friend in
                                Text(friend.name.split(whereSeparator: \.isWhitespace).prefix(2)
                                    .compactMap { $0.first }.map { String($0) }.joined().uppercased())
                                    .font(.subheadline.bold()).foregroundStyle(Palette.dashboardAccent)
                                    .frame(width: 34, height: 34)
                                    .background(Palette.card, in: Circle())
                                    .overlay { Circle().strokeBorder(Palette.dashboardAccent.opacity(0.35), lineWidth: 1) }
                            }
                        }
                        .accessibilityHidden(true)
                        Text("\(friendIDs.count) \(friendIDs.count == 1 ? "friend" : "friends")")
                            .font(.subheadline).foregroundStyle(Palette.dashboardSecondary)
                    }
                } else if !bills.isEmpty {
                    Label("All settled", systemImage: "checkmark.circle.fill")
                        .font(.title3.bold()).foregroundStyle(Palette.dashboardMint)
                    Text("You're all caught up with friends.")
                        .font(.subheadline).foregroundStyle(Palette.dashboardSecondary)
                } else {
                    Text("No shared bills").font(.title3.bold())
                    Text("Split a bill and keep track of repayments.")
                        .font(.subheadline).foregroundStyle(Palette.dashboardSecondary)
                }
            }
        }
        .accessibilityIdentifier("home.friendSplits")
    }

    private var shoppingTripCard: some View {
        DashboardActionCard(title: "Shopping trip", symbol: "basket.fill", accent: Palette.dashboardMint,
                            action: shoppingTrips.activeTrip == nil ? "Start a trip" : "Continue shopping") {
            ShoppingTripScreen(store: store, trips: shoppingTrips)
        } preview: {
            VStack(alignment: .leading, spacing: 10) {
                if let trip = shoppingTrips.activeTrip {
                    Text(trip.name).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                    let itemCount = trip.items.reduce(0) { $0 + $1.quantity }
                    Text("\(itemCount) \(itemCount == 1 ? "item" : "items") in your basket")
                        .font(.subheadline).foregroundStyle(Palette.dashboardSecondary)
                    ProgressView(value: trip.cap > 0 ?
                        min(1, max(0, NSDecimalNumber(decimal: trip.spent / trip.cap).doubleValue)) : 0)
                        .tint(trip.remaining < 0 ? Palette.dashboardAccent : Palette.dashboardMint)
                        .accessibilityLabel("Shopping cap used")
                    Text("\(LKR.string(abs(trip.remaining))) \(trip.remaining < 0 ? "over cap" : "left")")
                        .font(.subheadline.weight(.medium))
                } else {
                    Text("Ready to shop?").font(.title3.bold())
                    Text("Set a cap and track items as you shop.")
                        .font(.subheadline).foregroundStyle(Palette.dashboardSecondary)
                }
            }
        }
        .accessibilityIdentifier("home.shoppingTrip")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            let headerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(spacing: 8))
            headerLayout {
                HStack {
                    NavigationLink { SettingsScreen(store: store, notifications: store.notifications) } label: {
                        AccountAvatar(accountID: auth.user?.uid, name: auth.user?.displayName,
                                      photoURL: auth.profilePhotoURL, size: 38)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Profile and settings")
                    Text("Your money at a glance").font(.subheadline.bold()).foregroundStyle(.white)
                    Spacer()
                }
                Picker("Period", selection: $allTime) {
                    Text("Month").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.menu)
                .tint(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR \(Date.now.formatted(.dateTime.month(.wide)).uppercased()) BUDGET")
                    .font(.caption.bold()).tracking(1).foregroundStyle(.white.opacity(0.9))
                Text(store.budget > 0 ? LKR.string(max(0, left)) : "Set a budget")
                    .font(.system(size: balanceSize, weight: .bold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.65)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true).foregroundStyle(.white)
                Text(store.budget == 0 ? "plan your month in seconds" : left < 0 ? "over budget" : "still yours to spend")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85))
            }
            if store.budget > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(LKR.string(store.spentSoFar)) used of \(LKR.string(store.budget))")
                        .font(.footnote).foregroundStyle(.white.opacity(0.95))
                    ProgressView(value: usedRatio)
                        .tint(Color(red: 0.77, green: 0.95, blue: 0.49))
                    if left < 0 {
                        Label("Over budget by \(LKR.string(-left))", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.bold()).foregroundStyle(.white)
                    }
                }
            }
            HStack(spacing: 12) {
                LedgerIconTile(icon: .init(symbol: "calendar.badge.clock", color: Palette.dashboardMint), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("YOUR DAILY PACE").font(.footnote.bold()).foregroundStyle(Palette.dashboardSecondary)
                    Text(store.budget > 0 ? LKR.string(max(0, left) / Decimal(daysLeft)) : "Add a budget")
                        .font(.title3.bold().monospacedDigit()).foregroundStyle(Palette.ink)
                    Text(store.budget > 0 ? "per day · \(daysLeft) \(daysLeft == 1 ? "day" : "days") left" : "to see your daily pace")
                        .font(.subheadline).foregroundStyle(Palette.dashboardSecondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
            let metricsLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 8))
            metricsLayout {
                metric("INCOME", value: income, color: Color(red: 0.47, green: 0.95, blue: 0.85))
                if dynamicTypeSize.isAccessibilitySize {
                    Rectangle().fill(.white.opacity(0.35)).frame(height: 1)
                } else {
                    Rectangle().fill(.white.opacity(0.35)).frame(width: 1, height: 42)
                }
                metric("SPENT", value: expense, color: .white)
            }
            .padding(12)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
        }
        .padding(16)
        .background(LinearGradient(colors: [Palette.cranberry, Palette.plum], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 28))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }

    private func metric(_ title: String, value: Decimal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote.bold()).foregroundStyle(.white.opacity(0.95))
            Text(LKR.string(value)).font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.65)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                LedgerIconTile(icon: .init(symbol: "plus", color: Palette.cranberry), size: 36)
                Text("ADD TRANSACTIONS").font(.caption.bold()).foregroundStyle(.secondary)
            }
            Text("Log expense or income").font(.headline).foregroundStyle(Palette.ink)
            Text("Capture money movement so budgets stay accurate")
                .font(.footnote).foregroundStyle(.secondary)
            let actionLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 10))
                : AnyLayout(HStackLayout(spacing: 8))
            actionLayout {
                Button { add(.expense) } label: {
                    Label("Expenses", systemImage: "creditcard.fill")
                        .frame(maxWidth: .infinity).frame(minHeight: 44)
                }
                .buttonStyle(DashboardEntryButtonStyle(accent: Palette.dashboardAccent))
                Button { add(.income) } label: {
                    Label("Income", systemImage: "banknote.fill")
                        .frame(maxWidth: .infinity).frame(minHeight: 44)
                }
                .buttonStyle(DashboardEntryButtonStyle(accent: Palette.dashboardMint))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                LedgerIconTile(icon: .init(symbol: "clock.arrow.circlepath", color: Palette.iconPlum), size: 36)
                Text("Recent transactions").font(.headline).foregroundStyle(Palette.ink)
            }
            if store.entries.isEmpty {
                ContentUnavailableView("No transactions yet", systemImage: "tray", description: Text("Add an expense or income to get started."))
            } else {
                ForEach(store.entries.prefix(4)) { entry in
                    NavigationLink { EntryDetail(store: store, entry: entry) } label: {
                        EntryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
    }
}

private extension View {
    func dashboardCard() -> some View {
        self
            .frame(maxWidth: .infinity, minHeight: 270, alignment: .topLeading)
            .padding(20)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
    }
}
