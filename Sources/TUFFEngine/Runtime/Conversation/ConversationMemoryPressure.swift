import Dispatch
import Foundation

/// The callback only records pressure. The serialized inference owner drops
/// snapshots at the next request boundary, without racing a GPU copy/restore.
final class ConversationMemoryPressure: @unchecked Sendable {
    static let shared = ConversationMemoryPressure()
    private let lock = NSLock()
    private var pressured = false
    private let source: DispatchSourceMemoryPressure

    var isPressured: Bool { lock.withLock { pressured } }

    private init() {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            // Coalesced warning + normal events conservatively keep optional
            // retention disabled until an unambiguous normal notification.
            lock.withLock { pressured = !event.intersection([.warning, .critical]).isEmpty }
        }
        source.resume()
    }

    deinit { source.cancel() }
}
