import SwiftUI

struct WelcomeScreen: View {
    @ObservedObject var auth: AuthSession
    @ObservedObject var store: LedgerStore
    let finish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var page = 0
    @State private var path: [Route] = []

    private enum Route: Hashable { case signIn, registration, setup }
    private let titles = ["A clearer view\nof your money.", "Make room\nfor your plans.", "A little help,\nright on time."]
    private let subtitles = [
        "Bring your spending, income and budgets together. One calm place for every rupee.",
        "Set a monthly budget, plan an event or share a bill. Keep the things that matter in view.",
        "Choose reminders for saved places, so it's easier to record the little expenses you might forget."
    ]

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.pie.fill").foregroundStyle(.white.opacity(0.8))
                    Text("Ledgerly").font(.headline)
                    Spacer()
                    Button("Skip intro") { openAccount() }
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.top, 8)

                TabView(selection: $page) {
                    ForEach(0..<3, id: \.self) { index in
                        ScrollView {
                            VStack(spacing: 22) {
                                if !dynamicTypeSize.isAccessibilitySize {
                                    OnboardingArtwork(page: index, isActive: page == index)
                                        .dynamicTypeSize(.large)
                                        .frame(height: 270)
                                        .padding(.top, 24)
                                        .accessibilityHidden(true)
                                }
                                Text(titles[index])
                                    .font(.largeTitle.bold())
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(subtitles[index])
                                    .font(.body)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 20)
                            .frame(maxWidth: 520)
                            .frame(maxWidth: .infinity)
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                VStack(spacing: 14) {
                    HStack(spacing: 7) {
                        ForEach(0..<3, id: \.self) { index in
                            Capsule().fill(.white.opacity(page == index ? 1 : 0.3))
                                .frame(width: page == index ? 24 : 7, height: 7)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Introduction, page \(page + 1) of 3")
                    Button(page == 2 ? "Get started" : "Continue") {
                        if page == 2 { openAccount() }
                        else if reduceMotion { page += 1 }
                        else { withAnimation(.easeInOut(duration: 0.28)) { page += 1 } }
                    }
                    .buttonStyle(AccountPrimaryButtonStyle())
                    .accessibilityIdentifier("onboarding.continue")
                    if auth.user == nil {
                        HStack(spacing: 5) {
                            Text("Already have an account?").foregroundStyle(.white.opacity(0.8))
                            Button("Sign in") { path.append(.signIn) }.fontWeight(.semibold)
                        }
                        .font(.subheadline).foregroundStyle(.white)
                        .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background {
                LinearGradient(colors: [Palette.plum, Color(red: 0.21, green: 0.12, blue: 0.25)],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
                    .ignoresSafeArea()
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .signIn, .registration:
                    EmailAuthScreen(auth: auth, onSuccess: { path = [.setup] },
                                    startsWithRegistration: route == .registration,
                                    embeddedInNavigation: true,
                                    continueWithoutAccount: { path = [.setup] })
                case .setup:
                    FirstStepsScreen(store: store, auth: auth, finish: finish)
                        .toolbar(.visible, for: .navigationBar)
                }
            }
        }
        .tint(Palette.dashboardAccent)
    }

    private func openAccount() {
        path.append(auth.user == nil ? .registration : .setup)
    }
}

private struct OnboardingArtwork: View {
    let page: Int
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 0.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28).fill(Palette.mint.opacity(0.85))
                .rotationEffect(.degrees(-5)).padding(12)
            RoundedRectangle(cornerRadius: 28).fill(Color(red: 0.86, green: 0.39, blue: 0.56))
                .rotationEffect(.degrees(4)).padding(8)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: ["chart.pie.fill", "calendar.badge.clock", "mappin.and.ellipse"][page])
                        .font(.title3).foregroundStyle(Palette.plum)
                        .frame(width: 40, height: 40)
                        .background(Palette.plum.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    Text(["YOUR MONTHLY SNAPSHOT", "PLANS WORTH MAKING", "A HELPFUL REMINDER"][page])
                        .font(.caption.bold()).tracking(1).foregroundStyle(Palette.plum)
                }
                if page == 0 {
                    Text("Still yours to spend").font(.subheadline).foregroundStyle(.black.opacity(0.6))
                    Text("LKR 21,400").font(.largeTitle.bold()).foregroundStyle(Palette.plum)
                    progressBar
                    HStack {
                        Text("Income").foregroundStyle(Color(red: 0.05, green: 0.45, blue: 0.35))
                        Spacer()
                        Text("Spending").foregroundStyle(Palette.plum)
                    }.font(.footnote.weight(.medium))
                } else if page == 1 {
                    Text("Your next getaway").font(.title2.bold()).foregroundStyle(Palette.plum)
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().stroke(Palette.plum.opacity(0.1), lineWidth: 8)
                            Circle().trim(from: 0, to: progress)
                                .stroke(Palette.mint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: "sun.max.fill").font(.title2).foregroundStyle(Palette.plum)
                        }.frame(width: 66, height: 66)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("A plan for every occasion").font(.headline)
                            Text("Trips and celebrations").font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }.foregroundStyle(Palette.plum)
                    }
                    Text("Your everyday budget stays in view.")
                        .font(.footnote).foregroundStyle(.black.opacity(0.6))
                } else {
                    Text("At your saved place?").font(.title2.bold()).foregroundStyle(Palette.plum)
                    Label("Record an expense if you bought something.", systemImage: "bell.badge.fill")
                        .font(.body).foregroundStyle(Palette.plum)
                    Text("You choose the places and reminders.")
                        .font(.subheadline).foregroundStyle(.black.opacity(0.6))
                }
            }
            .multilineTextAlignment(.leading)
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 230, alignment: .leading)
            .background(Color(red: 1, green: 0.98, blue: 0.96), in: RoundedRectangle(cornerRadius: 26))
        }
        .frame(maxWidth: 380)
        .padding(.horizontal, 10)
        .onChange(of: isActive, initial: true) { _, active in
            if reduceMotion { progress = 0.72 }
            else { withAnimation(.easeOut(duration: 0.6)) { progress = active ? 0.72 : 0 } }
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.plum.opacity(0.12))
                Capsule().fill(Palette.mint).frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 7)
    }
}
