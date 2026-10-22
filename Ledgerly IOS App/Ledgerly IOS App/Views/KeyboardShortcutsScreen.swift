import SwiftUI

struct KeyboardShortcutsScreen: View {
    var body: some View {
        Form {
            Section {
                ForEach(LedgerKeyboardAction.allCases) { action in
                    LabeledContent(action.title, value: action.keys)
                }
            } header: {
                Text("With a connected keyboard")
            } footer: {
                Text("Use these shortcuts with a connected keyboard while Ledgerly is unlocked. Close any open form first.")
            }
        }
        .navigationTitle("Keyboard shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }
}
