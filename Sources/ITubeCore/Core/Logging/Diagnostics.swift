import Foundation

public enum DiagnosticEvent: Sendable, Equatable {
    case timeToReady(Duration)
    case providerResolution(Duration)
    case manifestRequest(Duration)
    case bufferEvent
    case playbackFailure(PlaybackError)
    case streamRefresh
    case pipTransitionFailure
}

/// Local, privacy-preserving, bounded diagnostics (ADR §66). Nothing leaves the device.
public actor DiagnosticsCenter {
    private var events: [(date: Date, event: DiagnosticEvent)] = []
    private let capacity: Int

    public init(capacity: Int = 200) { self.capacity = capacity }

    public func record(_ event: DiagnosticEvent) {
        events.append((.now, event))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }

    public func snapshot() -> [(date: Date, event: DiagnosticEvent)] { events }
    public func count(where predicate: @Sendable (DiagnosticEvent) -> Bool) -> Int { events.filter { predicate($0.event) }.count }
    public func clear() { events.removeAll() }
}
