import SwiftUI
import UIKit
import Combine

enum LedgerKeyboardAction: String, CaseIterable, Identifiable {
    case expense, income, budget, report, home, transactions, places, insights, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .expense: "New expense"
        case .income: "New income"
        case .budget: "Monthly budget"
        case .report: "Financial report"
        case .home: "Home"
        case .transactions: "Transactions"
        case .places: "Places"
        case .insights: "Insights"
        case .settings: "Profile & settings"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .expense: KeyboardShortcut("n", modifiers: .command)
        case .income: KeyboardShortcut("n", modifiers: [.command, .shift])
        case .budget: KeyboardShortcut("b", modifiers: .command)
        case .report: KeyboardShortcut("r", modifiers: [.command, .shift])
        case .home: KeyboardShortcut("1", modifiers: .command)
        case .transactions: KeyboardShortcut("2", modifiers: .command)
        case .places: KeyboardShortcut("3", modifiers: .command)
        case .insights: KeyboardShortcut("4", modifiers: .command)
        case .settings: KeyboardShortcut(",", modifiers: .command)
        }
    }

    var keys: String {
        switch self {
        case .expense: "⌘N"
        case .income: "⇧⌘N"
        case .budget: "⌘B"
        case .report: "⇧⌘R"
        case .home: "⌘1"
        case .transactions: "⌘2"
        case .places: "⌘3"
        case .insights: "⌘4"
        case .settings: "⌘,"
        }
    }
}

struct LedgerKeyboardActions {
    let perform: @MainActor (LedgerKeyboardAction) -> Void
}

private struct LedgerKeyboardActionsKey: FocusedValueKey {
    typealias Value = LedgerKeyboardActions
}

extension FocusedValues {
    var ledgerKeyboardActions: LedgerKeyboardActions? {
        get { self[LedgerKeyboardActionsKey.self] }
        set { self[LedgerKeyboardActionsKey.self] = newValue }
    }
}

struct LedgerKeyboardCommands: Commands {
    @FocusedValue(\.ledgerKeyboardActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            ForEach([LedgerKeyboardAction.expense, .income]) { action in
                Button(action.title) { actions?.perform(action) }
                    .keyboardShortcut(action.shortcut)
                    .disabled(actions == nil)
            }
        }
        CommandMenu("Ledgerly") {
            ForEach(LedgerKeyboardAction.allCases.filter { $0 != .expense && $0 != .income }) { action in
                Button(action.title) { actions?.perform(action) }
                    .keyboardShortcut(action.shortcut)
                    .disabled(actions == nil)
            }
        }
    }
}

/// Keep the command routed to its own scene and reject it while a sheet or
/// popover is presented, including editors owned by deeper navigation screens.
@MainActor
final class KeyboardWindowContext: ObservableObject {
    weak var window: UIWindow?
    var canOpenWorkspace: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.rootViewController?.presentedViewController == nil
    }
}

struct KeyboardWindowReader: UIViewRepresentable {
    let context: KeyboardWindowContext

    final class WindowProbe: UIView {
        weak var context: KeyboardWindowContext?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            context?.window = window
        }
    }

    func makeUIView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.context = self.context
        return view
    }

    func updateUIView(_ uiView: WindowProbe, context: Context) {
        uiView.context = self.context
    }
}
