import Foundation
import Sparkle

@MainActor final class RecoveryUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var probing = false
    var report: (String) -> Void = { _ in }
    let applicationSupport: URL

    init(applicationSupport: URL) { self.applicationSupport = applicationSupport }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        let metadata = RecoveryUpdateMetadata(properties: item.propertiesDictionary)
        guard metadata.isRecovery else { return }
        try RecoveryUpdatePolicy.checkForRunningApp(metadata,
            local: RecoveryUpdatePolicy.localVersions(applicationSupport: applicationSupport))
    }

    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        guard probing else { return nil }
        let installed = updater.hostBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return appcast.items.filter {
            RecoveryUpdateMetadata(properties: $0.propertiesDictionary).isRecovery
                && SUStandardVersionComparator.default.compareVersion($0.versionString, toVersion: installed) == .orderedDescending
        }.max {
            SUStandardVersionComparator.default.compareVersion($0.versionString, toVersion: $1.versionString) == .orderedAscending
        } ?? SUAppcastItem.empty()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard probing else { return }
        let metadata = RecoveryUpdateMetadata(properties: item.propertiesDictionary)
        if metadata.isRecovery {
            report("Recovery update \(item.displayVersionString) is available. Use Check for Updates to review and install it.")
        } else {
            report("No recovery update is available.")
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        if probing { report("No recovery update is available.") }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard probing else { return }
        probing = false
        if let error, (error as NSError).code != SUError.noUpdateError.rawValue {
            report("Recovery check could not finish: \(error.localizedDescription)")
        }
    }
}
