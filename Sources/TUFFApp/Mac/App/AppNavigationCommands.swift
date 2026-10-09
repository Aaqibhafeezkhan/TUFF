import TUFFMacPresentation
import SwiftUI

struct AppNavigationAction {
    let select: (AppDestination) -> Void
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
