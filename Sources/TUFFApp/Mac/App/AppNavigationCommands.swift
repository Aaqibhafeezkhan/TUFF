import TUFFMacPresentation
import SwiftUI

struct AppNavigationAction {
    let select: (AppDestination) -> Void
    /// Opens the chat after (+1) or before (-1) the open one, in sidebar
    /// order. Nil while chats can't be switched.
    var stepChat: ((Int) -> Void)?
    let focusComposer: () -> Void
}

extension Notification.Name {
    /// Asks the message box to take keyboard focus.
    static let tuffFocusComposer = Notification.Name("TUFFFocusComposer")
}

private struct AppNavigationActionKey: FocusedValueKey {
    typealias Value = AppNavigationAction
}

extension FocusedValues {
    var appNavigationAction: AppNavigationAction? {
        get { self[AppNavigationActionKey.self] }
        set { self[AppNavigationActionKey.self] = newValue }
    }
}

struct AppNavigationCommands: Commands {
    @FocusedValue(\.appNavigationAction) private var navigation

    var body: some Commands {
        CommandMenu("Navigate") {
            ForEach(AppDestination.allCases) { destinationButton($0) }
            Divider()
            // Control-Tab, as in Messages and Safari: Command-[ and ] are
            // text commands in some editors.
            Button("Next Chat") { navigation?.stepChat?(1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(navigation?.stepChat == nil)
            Button("Previous Chat") { navigation?.stepChat?(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(navigation?.stepChat == nil)
            Button("Message Box") { navigation?.focusComposer() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(navigation == nil)
        }
    }

    private func destinationButton(_ destination: AppDestination) -> some View {
        Button(destination.title) {
            navigation?.select(destination)
        }
        .keyboardShortcut(
            KeyEquivalent(Character(destination.keyboardShortcut)),
            modifiers: .command)
        .disabled(navigation == nil)
    }
}
