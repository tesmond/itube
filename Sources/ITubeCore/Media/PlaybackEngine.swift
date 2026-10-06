import AVFoundation
import Foundation
import Observation

/// What the engine reports outward. The coordinator fans these out to Now Playing, persistence and PiP.
public enum EngineNotification: Sendable, Equatable {
    case stateChanged(PlaybackState)
    case itemLoaded
    case rateChanged(Float)
    case progress(position: Duration, duration: Duration?)
    case seeked(Duration)
    case ended
}

public protocol AudioSessionControlling: AnyObject {
    @MainActor func activate()
    @MainActor func deactivate()
}

/// Owns the single active player and translates AVFoundation events into a stable domain model (ADR §7, §45, §46).
@MainActor @Observable
public final class PlaybackEngine {
    public static let supportedRates: [Float] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    private static let maxRefreshAttempts = 2

    // Observable state
    public private(set) var state: PlaybackState = .idle
    public private(set) var currentVideo: Video?
    public private(set) var resource: PlaybackResource?
    public private(set) var currentTime: Duration = .zero
    public private(set) var duration: Duration?
    public private(set) var rate: Float = 1.0
    public private(set) var quality: VideoQuality = .auto
    public private(set) var availableQualities: [VideoQuality] = [.auto]
    public private(set) var isLooping = false
    public private(set) var isMediaLoaded = false

    public var player: AVPlayer? { backend.avPlayer }
    public var skipRanges: [ClosedRange<Duration>] = []
    public var onNotification: (@MainActor (EngineNotification) -> Void)?

    @ObservationIgnored private let backend: any PlayerBackend
    @ObservationIgnored private let selector: StreamSelector
    @ObservationIgnored private let audioSession: (any AudioSessionControlling)?
    @ObservationIgnored private let diagnostics: DiagnosticsCenter?
    @ObservationIgnored private var refresh: (@Sendable (VideoID) async throws -> PlaybackResource)?
    @ObservationIgnored private var policy = StreamPolicy()
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var skipTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshAttempts = 0
    @ObservationIgnored private var lastRefreshPosition: Duration = .zero
    @ObservationIgnored private var knownHLSHeights: [Int] = []
    @ObservationIgnored public private(set) var wantsToPlay = false

    public init(
        backend: any PlayerBackend, selector: StreamSelector = StreamSelector(),
        audioSession: (any AudioSessionControlling)? = nil, diagnostics: DiagnosticsCenter? = nil,
        refresh: (@Sendable (VideoID) async throws -> PlaybackResource)? = nil
    ) {
        self.backend = backend; self.selector = selector; self.audioSession = audioSession
        self.diagnostics = diagnostics; self.refresh = refresh
        startEventLoop()
    }

    public func setRefreshHandler(_ handler: (@Sendable (VideoID) async throws -> PlaybackResource)?) { refresh = handler }

    // MARK: Loading

    /// Marks that resolution has begun. The previous media keeps playing until the new item is ready.
    public func beginResolving(_ video: Video) {
        generation += 1
        recoveryTask?.cancel()
        refreshAttempts = 0
        lastRefreshPosition = .zero
        knownHLSHeights = []
        if !isMediaLoaded { currentVideo = video }
        setState(.resolving)
    }

    /// Shows a restored session in the UI without loading anything (no audio after a cold launch — ADR §72).
    public func prepareRestored(video: Video, position: Duration, rate: Float, quality: VideoQuality) {
        currentVideo = video; currentTime = position; duration = video.duration
        self.rate = rate; self.quality = quality
        setState(.idle)
    }

    public func load(video: Video, resource: PlaybackResource, policy: StreamPolicy, startAt: Duration?, autoplay: Bool, hlsHeights: [Int] = []) async throws {
        generation += 1
        let myGeneration = generation
        self.policy = policy
        setState(.loading)
        let started = ContinuousClock.now
        do {
            let media = try selector.select(resource, policy: policy)
            try await backend.load(media, startAt: startAt, quality: policy.quality)
            guard myGeneration == generation else { throw CancellationError() }   // superseded by a newer load
            self.resource = resource
            currentVideo = video
            currentTime = startAt ?? .zero
            duration = resource.duration ?? video.duration
            quality = policy.quality
            if !hlsHeights.isEmpty { knownHLSHeights = hlsHeights }
            availableQualities = selector.availableQualities(resource, policy: policy, hlsHeights: knownHLSHeights)
            isMediaLoaded = true
            backend.setRate(rate)
            setState(.ready)
            notify(.itemLoaded)
            await diagnostics?.record(.timeToReady(ContinuousClock.now - started))
            if autoplay { play() }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let mapped = PlaybackError(error)
            guard myGeneration == generation else { throw CancellationError() }
            setState(.failed(mapped))
            await diagnostics?.record(.playbackFailure(mapped))
            throw mapped
        }
    }

    public func setAvailableHLSHeights(_ heights: [Int]) {
        guard let resource else { return }
        knownHLSHeights = heights
        availableQualities = selector.availableQualities(resource, policy: policy, hlsHeights: heights)
    }

    // MARK: Transport

    public func play() {
        guard isMediaLoaded else { return }
        wantsToPlay = true
        audioSession?.activate()
        if state == .ended { Task { [weak self] in await self?.seek(to: .zero) } }
        backend.play(rate: rate)
    }

    public func pause() {
        wantsToPlay = false
        backend.pause()
    }

    public func togglePlayPause() {
        if state.isActivelyPlaying { pause() } else { play() }
    }

    public func seek(to time: Duration) async {
        guard isMediaLoaded else { return }
        let upper = duration ?? time
        let clamped = min(max(time, .zero), upper)
        currentTime = clamped
        await backend.seek(to: clamped)
        notify(.seeked(clamped))
        notify(.progress(position: clamped, duration: duration))
    }

    public func seek(by delta: Duration) async { await seek(to: currentTime + delta) }

    public func setRate(_ newRate: Float) {
        let clamped = min(max(newRate, 0.25), 2.0)
        rate = clamped
        backend.setRate(clamped)
        notify(.rateChanged(clamped))
    }

    public func setLooping(_ on: Bool) { isLooping = on }

    public func setTimeObserverInterval(_ seconds: Double) { backend.setTimeObserverInterval(seconds) }

    /// Quality is independent of UI (ADR §84.12). HLS only needs a cap; progressive/composition re-select and reload.
    public func setQuality(_ newQuality: VideoQuality) async {
        guard let resource, let video = currentVideo, newQuality != quality else { return }
        policy.quality = newQuality
        if selector.isAdaptive(resource) {
            quality = newQuality
            backend.applyQuality(newQuality)
        } else {
            await reload(video: video, resource: resource, resumeAt: currentTime, resumePlaying: wantsToPlay)
        }
    }

    public func stop() {
        generation += 1
        recoveryTask?.cancel()
        wantsToPlay = false
        backend.stop()
        isMediaLoaded = false
        resource = nil
        currentVideo = nil
        duration = nil
        currentTime = .zero
        setState(.idle)
        audioSession?.deactivate()
    }

    /// Cancels everything. Call when the app is torn down.
    public func shutdown() {
        eventTask?.cancel(); recoveryTask?.cancel(); skipTask?.cancel()
        backend.shutdown()
    }

    public func fail(_ error: PlaybackError) { setState(.failed(error)) }

    // MARK: Events

    private func startEventLoop() {
        let events = backend.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    func handle(_ event: PlayerEvent) {
        switch event {
        case .timeControl(let tc):
            switch tc {
            case .playing: setState(.playing)
            case .waiting:
                if wantsToPlay { setState(.buffering); Task { [diagnostics] in await diagnostics?.record(.bufferEvent) } }
            case .paused:
                if state == .playing || state == .buffering { wantsToPlay = false; setState(.paused) }
            }
        case .time(let t):
            currentTime = t
            notify(.progress(position: t, duration: duration))
            skipIfNeeded(at: t)
        case .duration(let d):
            if let d { duration = d } else if duration == nil { duration = resource?.duration }
        case .stalled:
            if wantsToPlay { setState(.buffering) }
        case .ended:
            if isLooping {
                Task { [weak self] in await self?.seek(to: .zero); self?.play() }
            } else {
                wantsToPlay = false
                setState(.ended)
                notify(.ended)
            }
        case .failed(let error):
            handleFailure(error)
        }
    }

    private func handleFailure(_ error: PlaybackError) {
        // Expired signed URL → resolve fresh, restore position/rate/quality, continue (ADR §49). Bounded, never infinite.
        // Long streams may legitimately expire again much later, so the budget renews after a minute of real progress.
        if currentTime - lastRefreshPosition >= .seconds(60) { refreshAttempts = 0 }
        if error == .streamExpired, refreshAttempts < Self.maxRefreshAttempts, refresh != nil, let video = currentVideo {
            refreshAttempts += 1
            lastRefreshPosition = currentTime
            let resumeAt = currentTime
            let resume = wantsToPlay
            recoveryTask?.cancel()
            recoveryTask = Task { [weak self] in
                guard let self, let refresh = self.refresh else { return }
                await self.diagnostics?.record(.streamRefresh)
                do {
                    let fresh = try await refresh(video.id)
                    try Task.checkCancellation()
                    await self.reload(video: video, resource: fresh, resumeAt: resumeAt, resumePlaying: resume)
                } catch is CancellationError {
                } catch {
                    self.setState(.failed(PlaybackError(error)))
                }
            }
        } else {
            setState(.failed(error))
            Task { [diagnostics] in await diagnostics?.record(.playbackFailure(error)) }
        }
    }

    private func reload(video: Video, resource: PlaybackResource, resumeAt: Duration, resumePlaying: Bool) async {
        do {
            let savedRefresh = refreshAttempts
            try await load(video: video, resource: resource, policy: policy, startAt: resumeAt, autoplay: resumePlaying)
            refreshAttempts = savedRefresh
        } catch is CancellationError {
        } catch {
            // `load` already set `.failed`.
        }
    }

    private func skipIfNeeded(at time: Duration) {
        guard skipTask == nil, state == .playing,
              let range = skipRanges.first(where: { $0.contains(time) && time < $0.upperBound - .milliseconds(300) }) else { return }
        skipTask = Task { [weak self] in
            await self?.seek(to: range.upperBound)
            self?.skipTask = nil
        }
    }

    private func setState(_ new: PlaybackState) {
        guard state != new else { return }
        state = new
        notify(.stateChanged(new))
    }

    private func notify(_ n: EngineNotification) { onNotification?(n) }
}

extension StreamSelector {
    func isAdaptive(_ resource: PlaybackResource) -> Bool { resource.videoStreams.contains(where: \.isHLS) }
}
