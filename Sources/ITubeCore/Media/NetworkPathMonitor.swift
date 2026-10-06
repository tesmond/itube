import Foundation
import Network

/// Reports whether the current path is expensive/constrained (cellular, Low Data Mode) as an async stream.
/// No polling: `NWPathMonitor` pushes changes, and the stream's termination cancels the monitor.
public struct NetworkPathMonitor: Sendable {
    public let updates: AsyncStream<Bool>

    public init() {
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in continuation.yield(path.isExpensive || path.isConstrained) }
            monitor.start(queue: DispatchQueue(label: "com.tesmond.itube.network-path", qos: .utility))
            continuation.onTermination = { _ in monitor.cancel() }
        }
    }
}
