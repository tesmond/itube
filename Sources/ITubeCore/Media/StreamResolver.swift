import Foundation

public protocol StreamResolving: Sendable {
    /// `forceRefresh` bypasses every cache so expired signed URLs are replaced (ADR §49).
    func resolve(_ id: VideoID, forceRefresh: Bool, adSuppression: Bool) async throws -> PlaybackResource
}

/// Provider → (cache) → AdSuppressionEngine. Coalesces concurrent requests for one video. An actor, so no locks.
public actor StreamResolver: StreamResolving {
    private let registry: ProviderRegistry
    private let suppression: AdSuppressionEngine
    private let diagnostics: DiagnosticsCenter?
    private var inFlight: [VideoID: Task<PlaybackResource, any Error>] = [:]

    public init(registry: ProviderRegistry, suppression: AdSuppressionEngine = AdSuppressionEngine(), diagnostics: DiagnosticsCenter? = nil) {
        self.registry = registry; self.suppression = suppression; self.diagnostics = diagnostics
    }

    public func resolve(_ id: VideoID, forceRefresh: Bool, adSuppression: Bool) async throws -> PlaybackResource {
        guard let provider = registry.primary else { throw PlaybackError.unavailable }
        if forceRefresh {
            inFlight[id]?.cancel(); inFlight[id] = nil
            await provider.invalidatePlaybackResource(for: id)
        }
        let task: Task<PlaybackResource, any Error>
        if let existing = inFlight[id] {
            task = existing
        } else {
            let diagnostics = self.diagnostics
            task = Task {
                let started = ContinuousClock.now
                let resource = try await provider.playbackResource(for: id)
                await diagnostics?.record(.providerResolution(ContinuousClock.now - started))
                return resource
            }
            inFlight[id] = task
        }
        defer { if inFlight[id] == task { inFlight[id] = nil } }
        do {
            let resource = try await task.value
            try Task.checkCancellation()   // a shared task keeps running for other waiters; this caller still stops
            return suppression.process(resource, enabled: adSuppression)
        } catch {
            if !(error is CancellationError) {
                Log.playback.error("Resolve failed for \(id.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            throw PlaybackError(error)
        }
    }
}
