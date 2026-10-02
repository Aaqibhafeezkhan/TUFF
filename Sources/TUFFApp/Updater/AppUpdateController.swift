import Foundation
import Observation
import Sparkle

public struct AppUpdateConfiguration: Equatable, Sendable {
    public let feedURL: URL
    public let publicKey: String

    public init(feedURL: URL, publicKey: String) {
        self.feedURL = feedURL
        self.publicKey = publicKey
    }

    public static func resolve(
        infoDictionary: [String: Any]?
    ) -> Result<Self, AppUpdateConfigurationError> {
        guard let infoDictionary,
              let feed = (infoDictionary["SUFeedURL"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let key = (infoDictionary["SUPublicEDKey"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !feed.isEmpty, !key.isEmpty else {
            return .failure(.missingConfiguration)
        }
        guard let feedURL = URL(string: feed),
              feedURL.scheme?.lowercased() == "https",
              feedURL.host != nil else {
            return .failure(.insecureOrInvalidFeedURL)
        }
        guard let keyData = Data(base64Encoded: key), keyData.count == 32 else {
            return .failure(.invalidPublicKey)
        }
        return .success(Self(feedURL: feedURL, publicKey: key))
    }
}

public enum AppUpdateConfigurationError: Error, Equatable, Sendable {
    case missingConfiguration
    case insecureOrInvalidFeedURL
    case invalidPublicKey

    public var userMessage: String {
        switch self {
        case .missingConfiguration:
            "Update signing is not configured in this build."
        case .insecureOrInvalidFeedURL:
            "The update feed must be a valid HTTPS URL."
        case .invalidPublicKey:
            "The embedded update-signing public key is invalid."
        }
    }
}

/// Owns Sparkle's standard UI and persists update preferences through
/// Sparkle's host-bundle defaults. Invalid or unsigned configurations never
/// start an updater.
@MainActor
@Observable
public final class AppUpdateController {
    public var recoveryMessage: String?
    @ObservationIgnored private var recoveryDelegate: RecoveryUpdaterDelegate?
    public let configuration: AppUpdateConfiguration?
    public private(set) var unavailableReason: String?
    public private(set) var allowsAutomaticUpdates = false

    // Sparkle owns the persisted values; expose its confirmed state to SwiftUI.
    public var automaticallyChecksForUpdates: Bool {
        get { checksForUpdates }
        set {
            guard let updater = updater else { return }
            updater.automaticallyChecksForUpdates = newValue
            checksForUpdates = updater.automaticallyChecksForUpdates
            allowsAutomaticUpdates = updater.allowsAutomaticUpdates
            // Automatic downloads require automatic checks.
            if !checksForUpdates { automaticallyDownloadsUpdates = false }
        }
    }
    public var automaticallyDownloadsUpdates: Bool {
        get { downloadsUpdates }
        set {
            guard let updater = updater else { return }
            updater.automaticallyDownloadsUpdates = newValue
            downloadsUpdates = updater.automaticallyDownloadsUpdates
        }
    }

    private var checksForUpdates = false
    private var downloadsUpdates = false

    @ObservationIgnored
    private var updater: SPUUpdater?
    @ObservationIgnored private var userDriver: RecoveryUserDriver?

    public init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        switch AppUpdateConfiguration.resolve(infoDictionary: infoDictionary) {
        case .failure(let error):
            configuration = nil
            unavailableReason = error.userMessage
        case .success(let configuration):
            self.configuration = configuration
            let delegate = RecoveryUpdaterDelegate(applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!)
            recoveryDelegate = delegate
            delegate.report = { [weak self] in self?.recoveryMessage = $0 }
            let driver = RecoveryUserDriver(hostBundle: .main, delegate: nil)
            driver.checkCompatibility = { item in
                let metadata = RecoveryUpdateMetadata(properties: item.propertiesDictionary)
                guard metadata.isRecovery else { return }
                try RecoveryUpdatePolicy.checkForRunningApp(metadata,
                    local: RecoveryUpdatePolicy.localVersions(applicationSupport: delegate.applicationSupport))
            }
            driver.report = { [weak self] in self?.recoveryMessage = $0 }
            userDriver = driver
            let controller = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                userDriver: driver, delegate: delegate)
            do {
                try controller.start()
                updater = controller
                checksForUpdates = controller.automaticallyChecksForUpdates
                downloadsUpdates = controller.automaticallyDownloadsUpdates
                allowsAutomaticUpdates = controller.allowsAutomaticUpdates
                // Sparkle's own scheduler only checks once its interval has
                // elapsed since the last check, so a launch shortly after the
                // previous one would otherwise check for nothing. Sparkle's
                // header docs recommend calling this once, right after
                // starting, to force a check on every launch instead.
                if checksForUpdates {
                    controller.checkForUpdatesInBackground()
                }
            } catch {
                unavailableReason = "The updater could not start: \(error)"
            }
        }
    }

    public var isAvailable: Bool { updater != nil }

    public var canCheckForUpdates: Bool {
        updater?.canCheckForUpdates ?? false
    }

    public func checkForRecoveryUpdate() {
        guard let updater = updater, updater.canCheckForUpdates else { return }
        recoveryMessage = nil
        recoveryDelegate?.probing = true
        updater.checkForUpdateInformation()
    }

    public func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }
}
