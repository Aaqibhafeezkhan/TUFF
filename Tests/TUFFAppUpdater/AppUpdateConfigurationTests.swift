import Foundation
import Observation
import Testing
@testable import TUFFAppUpdater

@Suite struct AppUpdateConfigurationTests {
    private let publicKey = Data(repeating: 0xA5, count: 32).base64EncodedString()

    @Test @MainActor func updateAvailabilityInvalidatesObservationWithoutModelActivity() {
        let controller = AppUpdateController(infoDictionary: nil)
        let invalidations = AvailabilityInvalidations()
        withObservationTracking {
            #expect(!controller.canCheckForUpdates)
        } onChange: {
            invalidations.increment()
        }
        controller.setCheckAvailability(true)
        #expect(controller.canCheckForUpdates)
        #expect(invalidations.count == 1)
        controller.setCheckAvailability(false)
        #expect(!controller.canCheckForUpdates)
    }

    @Test func acceptsSignedHTTPSFeed() throws {
        let result = AppUpdateConfiguration.resolve(infoDictionary: [
            "SUFeedURL": "https://github.com/tuff-app/TUFF/releases/latest/download/appcast.xml",
            "SUPublicEDKey": publicKey,
        ])
        let configuration = try result.get()
        #expect(configuration.feedURL.scheme == "https")
        #expect(configuration.publicKey == publicKey)
    }

    @Test func missingConfigurationFailsClosed() {
        #expect(AppUpdateConfiguration.resolve(infoDictionary: nil)
            == .failure(.missingConfiguration))
        #expect(AppUpdateConfiguration.resolve(infoDictionary: [:])
            == .failure(.missingConfiguration))
    }

    @Test func rejectsUnsignedOrInsecureConfiguration() {
        #expect(AppUpdateConfiguration.resolve(infoDictionary: [
            "SUFeedURL": "http://example.com/appcast.xml",
            "SUPublicEDKey": publicKey,
        ]) == .failure(.insecureOrInvalidFeedURL))
        #expect(AppUpdateConfiguration.resolve(infoDictionary: [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": "not-a-public-key",
        ]) == .failure(.invalidPublicKey))
    }
}

private final class AvailabilityInvalidations: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
