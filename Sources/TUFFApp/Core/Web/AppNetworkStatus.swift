import Foundation
import Observation
#if canImport(Network)
import Network
#endif

/// Connectivity is a hint, not proof that a particular provider is reachable.
/// An unknown initial state allows requests until the monitor reports a path.
@MainActor
@Observable
public final class AppNetworkStatus {
    public internal(set) var isOffline = false
    #if canImport(Network)
    @ObservationIgnored private let monitor: NWPathMonitor?
    #endif

    public init(monitorsConnectivity: Bool = true) {
        #if canImport(Network)
        let monitor = monitorsConnectivity ? NWPathMonitor() : nil
        self.monitor = monitor
        monitor?.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor [weak self] in self?.isOffline = offline }
        }
        monitor?.start(queue: DispatchQueue(label: "TUFF.connectivity"))
        #endif
    }

    deinit {
        #if canImport(Network)
        monitor?.cancel()
        #endif
    }
}
