import Foundation
import Sparkle
import Testing
@testable import TUFFAppUpdater

@Suite struct RecoveryUpdatePolicyTests {
    private var valid: [AnyHashable: Any] {
        ["tuff:recovery": "true", "tuff:chatsSchema": "2", "tuff:appSettingsVersion": "7",
         "tuff:backgroundSettingsVersion": "1", "tuff:withdrawnVersion": "7.0.0"]
    }
    @MainActor @Test func resumedAndReadyChoicesRecheckDataWithoutChangingPreferences() {
        let driver = RecoveryUserDriver(hostBundle: .main, delegate: nil)
        let item = SUAppcastItem.empty()
        var supported = true
        var checks = 0
        driver.checkCompatibility = { _ in
            checks += 1
            if !supported { throw RecoveryUpdatePolicy.CompatibilityError.newerData }
        }
        #expect(driver.checked(item, choice: .install) == .install)
        supported = false
        #expect(driver.checked(item, choice: .install) == .skip)
        #expect(driver.checked(item, choice: .dismiss) == .skip)
        #expect(driver.checked(item, choice: .skip) == .skip)
        #expect(checks == 3)
    }
    @Test func healthyAffectedAndWithdrawnClientsRequireANewerVersion() {
        for installed in ["6.1.0", "7.0.0", "7.0.1"] {
            #expect(SUStandardVersionComparator.default.compareVersion("7.0.2", toVersion: installed) == .orderedDescending)
        }
        #expect(SUStandardVersionComparator.default.compareVersion("6.1.0", toVersion: "7.0.0") == .orderedAscending)
    }
    @Test func recoveryMetadataIsKeptInSparkleProperties() throws {
        let item = try #require(SUAppcastItem(dictionary: valid.merging([
            "enclosure": ["url": "https://example.com/TUFF.zip", "sparkle:version": "7.0.1", "length": "10"],
            "sparkle:version": "7.0.1"], uniquingKeysWith: { _, new in new })))
        let metadata = RecoveryUpdateMetadata(properties: item.propertiesDictionary)
        #expect(metadata.isRecovery)
        #expect(metadata.supported == .current)
        #expect(metadata.withdrawnVersion == "7.0.0")
        try RecoveryUpdatePolicy.check(metadata, local: .current)
    }
    @Test func refusesMissingMetadataAndAnyNewerFormat() throws {
        let legacy = RecoveryUpdateMetadata(properties: valid.merging(["tuff:chatsSchema": "1"], uniquingKeysWith: { _, new in new }))
        let localLegacy = TUFFDataVersions(chats: 1, appSettings: 7, backgroundSettings: 1)
        try RecoveryUpdatePolicy.check(legacy, local: localLegacy)
        #expect(throws: RecoveryUpdatePolicy.CompatibilityError.newerData) {
            try RecoveryUpdatePolicy.checkForRunningApp(legacy, local: localLegacy)
        }
        #expect(throws: RecoveryUpdatePolicy.CompatibilityError.missingMetadata) {
            try RecoveryUpdatePolicy.check(.init(properties: ["tuff:recovery": "true"]), local: .current)
        }
        for local in [TUFFDataVersions(chats: 3, appSettings: 7, backgroundSettings: 1),
                      .init(chats: 2, appSettings: 8, backgroundSettings: 1),
                      .init(chats: 2, appSettings: 7, backgroundSettings: 2)] {
            #expect(throws: RecoveryUpdatePolicy.CompatibilityError.newerData) {
                try RecoveryUpdatePolicy.check(.init(properties: valid), local: local)
            }
        }
        try RecoveryUpdatePolicy.check(.init(properties: [:]), local: .init(chats: 99, appSettings: 99, backgroundSettings: 99))
    }
    @Test func localStampReadingDoesNotModifyDataAndFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TUFFRecoveryData-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try RecoveryUpdatePolicy.localVersions(applicationSupport: root) == .current)
        let file = root.appendingPathComponent("TUFF/Models/mac-app-settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(#"{"version":8,"unrecognized":"untouched"}"#.utf8)
        try data.write(to: file)
        #expect(try RecoveryUpdatePolicy.localVersions(applicationSupport: root).appSettings == 8)
        #expect(try Data(contentsOf: file) == data)
        try Data(#"{"version":true}"#.utf8).write(to: file)
        #expect(throws: RecoveryUpdatePolicy.CompatibilityError.unreadableData) {
            try RecoveryUpdatePolicy.localVersions(applicationSupport: root)
        }
    }
}
