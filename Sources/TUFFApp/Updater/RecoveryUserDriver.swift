import Foundation
import Sparkle

/// Keeps Sparkle's standard UI while checking resumed and ready installations.
@MainActor final class RecoveryUserDriver: SPUStandardUserDriver {
    var checkCompatibility: (SUAppcastItem) throws -> Void = { _ in }
    var report: (String) -> Void = { _ in }
    private var candidate: SUAppcastItem?

    func checked(_ item: SUAppcastItem, choice: SPUUserUpdateChoice) -> SPUUserUpdateChoice {
        guard choice != .skip else { return choice }
        do { try checkCompatibility(item); return choice }
        catch { report(error.localizedDescription); return .skip }
    }

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        candidate = appcastItem
        do { try checkCompatibility(appcastItem) }
        catch { report(error.localizedDescription); reply(.skip); return }
        super.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
            guard let self else { reply(.skip); return }
            reply(self.checked(appcastItem, choice: choice))
        }
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let candidate else { reply(.skip); return }
        do { try checkCompatibility(candidate) }
        catch { report(error.localizedDescription); reply(.skip); return }
        super.showReady(toInstallAndRelaunch: { [weak self] choice in
            guard let self else { reply(.skip); return }
            reply(self.checked(candidate, choice: choice))
        })
    }
}
