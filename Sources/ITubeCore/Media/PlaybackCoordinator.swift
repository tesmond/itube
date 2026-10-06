import AVFoundation
import Foundation
import Observation

public enum AppLifecycle: Sendable { case active, inactive, background }

/// Orchestrates one playback session across every surface — full player, mini player, background, PiP,
/// Lock Screen, AirPlay (ADR §17, §36). All surfaces drive the one `PlaybackEngine`; there is no second state.
@MainActor @Observable
public final class PlaybackCoordinator {
    public let engine: PlaybackEngine
    public let queue: QueueManager
    public let subtitles: SubtitleManager
    public let pip: PiPManager
    public let sleepTimer: SleepTimer
    public let videoView: PlayerLayerView

    public private(set) var isPlayerPresented = false
    public private(set) var details: VideoDetails?
    public private(set) var isVideoSurfaceAttached = true
    public private(set) var isExpensiveNetwork = false

    @ObservationIgnored private let resolver: any StreamResolving
    @ObservationIgnored private let videos: VideoService
    @ObservationIgnored private let history: any HistoryStoring
    @ObservationIgnored private let sessionStore: any SessionStoring
    @ObservationIgnored private let settings: SettingsManager
    @ObservationIgnored private let nowPlaying: NowPlayingManager
    @ObservationIgnored private let audio: AudioSessionManager
    @ObservationIgnored private let manifests: ManifestLoader
    @ObservationIgnored private let suppression: AdSuppressionEngine
    @ObservationIgnored private let skipEngine = SegmentSkipEngine()

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var detailsTask: Task<Void, Never>?
    @ObservationIgnored private var hlsTask: Task<Void, Never>?
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private var phase: AppLifecycle = .active
    @ObservationIgnored private var pendingRestorePosition: Duration?
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var watched: Double = 0
    @ObservationIgnored private var lastProgress: Duration?
    @ObservationIgnored private var didRecordHistory = false
    @ObservationIgnored private var lastPersist = ContinuousClock.now

    public init(
        backend: any PlayerBackend, resolver: any StreamResolving, videos: VideoService, history: any HistoryStoring,
        sessionStore: any SessionStoring, settings: SettingsManager, http: any HTTPClient, images: ImageLoader?,
        suppression: AdSuppressionEngine = AdSuppressionEngine(), diagnostics: DiagnosticsCenter? = nil,
        network: NetworkPathMonitor = NetworkPathMonitor()
    ) {
        self.resolver = resolver; self.videos = videos; self.history = history; self.sessionStore = sessionStore
        self.settings = settings; self.suppression = suppression
        self.manifests = ManifestLoader(http: http)
        let audio = AudioSessionManager()
        self.audio = audio
        self.nowPlaying = NowPlayingManager(images: images)
        self.queue = QueueManager()
        self.subtitles = SubtitleManager(http: http)
        self.pip = PiPManager()
        self.sleepTimer = SleepTimer()
        self.videoView = PlayerLayerView()
        self.engine = PlaybackEngine(backend: backend, audioSession: audio, diagnostics: diagnostics)

        engine.setRefreshHandler { [resolver, settings] id in
            let ads = await settings.settings.adSuppression
            return try await resolver.resolve(id, forceRefresh: true, adSuppression: ads)
        }
        wire()
        applySettings()
        networkTask = Task { [weak self] in
            for await expensive in network.updates { self?.isExpensiveNetwork = expensive }
        }
    }

    /// The video the UI should show: the requested one immediately, even while its stream is still resolving.
    public var displayedVideo: Video? { queue.queue.current ?? engine.currentVideo }

    // MARK: Public controls

    /// Starts a user-initiated video. The current item keeps playing until the replacement is ready (ADR §8).
    public func play(_ video: Video, upcoming: [Video]? = nil, startAt: Duration? = nil, present: Bool = true) {
        queue.start(with: video, upcoming: upcoming)
        if present { isPlayerPresented = true }
        startLoad(video, startAt: startAt, autoplay: true)
    }

    public func togglePlayPause() {
        if engine.isMediaLoaded { engine.togglePlayPause(); return }
        if let current = queue.queue.current {            // restored session: load lazily, only on explicit user action
            let start = pendingRestorePosition
            pendingRestorePosition = nil
            startLoad(current, startAt: start, autoplay: true)
        }
    }

    public func resumePlayback() { if !engine.state.isActivelyPlaying { togglePlayPause() } }
    public func pausePlayback() { engine.pause() }

    public func next() {
        if let n = queue.advance() { startLoad(n, startAt: nil, autoplay: true) }
        else if let candidate = autoplayCandidate() { play(candidate, present: false) }
    }

    public func previous() {
        if engine.currentTime > .seconds(3) { Task { [engine] in await engine.seek(to: .zero) }; return }
        if let p = queue.retreat() { startLoad(p, startAt: nil, autoplay: true) }
    }

    public func presentPlayer() { isPlayerPresented = true }
    public func dismissPlayer() { isPlayerPresented = false }

    /// Fully stops and clears the session (mini-player close button).
    public func closeSession() {
        loadTask?.cancel(); detailsTask?.cancel(); hlsTask?.cancel()
        engine.stop()
        queue.clearAll()
        details = nil
        nowPlaying.clear()
        isPlayerPresented = false
        Task { [sessionStore] in await sessionStore.clear() }
    }

    public func prefetch(_ id: VideoID) {
        Task { [resolver, settings] in
            let ads = settings.settings.adSuppression
            _ = try? await resolver.resolve(id, forceRefresh: false, adSuppression: ads)   // warms the resolver/provider cache
        }
    }

    public func applySettings() {
        let s = settings.settings
        pip.automaticallyStartsFromInline = s.automaticPiP
        if !engine.isMediaLoaded { engine.setRateIfIdle(s.playbackSpeed) }
        updateSurface()
    }

    public func lifecycleChanged(_ new: AppLifecycle) {
        phase = new
        switch new {
        case .background:
            persistSession()
            engine.setTimeObserverInterval(5)       // fewer wakeups while nothing is on screen (ADR §57)
            if !settings.settings.backgroundPlayback, !pip.isActive, engine.state.isActivelyPlaying { engine.pause() }
        case .active:
            engine.setTimeObserverInterval(0.5)
        case .inactive: break
        }
        updateSurface()
    }

    /// Restores queue/position metadata without starting playback (ADR §72).
    public func restoreSession() async {
        guard let session = await sessionStore.load(), let current = session.queue.current else { return }
        queue.restore(session.queue)
        pendingRestorePosition = Duration(seconds: session.position)
        engine.prepareRestored(video: current, position: Duration(seconds: session.position), rate: session.rate, quality: session.quality)
        updateNowPlayingAvailability()
    }

    public func shutdown() {
        loadTask?.cancel(); detailsTask?.cancel(); hlsTask?.cancel(); networkTask?.cancel()
        engine.shutdown(); audio.shutdown(); nowPlaying.shutdown(); pip.teardown()
    }

    // MARK: Loading

    private func startLoad(_ video: Video, startAt: Duration?, autoplay: Bool) {
        loadTask?.cancel(); detailsTask?.cancel(); hlsTask?.cancel()
        pendingRestorePosition = nil
        engine.beginResolving(video)
        details = nil
        watched = 0; lastProgress = nil; didRecordHistory = false
        updateNowPlayingAvailability()

        detailsTask = Task { [weak self, videos] in
            let d = try? await videos.details(for: video.id)
            guard !Task.isCancelled, let self, self.queue.queue.current?.id == video.id else { return }
            self.details = d
        }
        loadTask = Task { [weak self] in
            await self?.performLoad(video, startAt: startAt, autoplay: autoplay)
        }
    }

    private func performLoad(_ video: Video, startAt: Duration?, autoplay: Bool) async {
        let s = settings.settings
        do {
            let resource = try await resolver.resolve(video.id, forceRefresh: false, adSuppression: s.adSuppression)
            try Task.checkCancellation()
            let start = await resumeStart(for: video, explicit: startAt)
            try Task.checkCancellation()
            let policy = StreamPolicy(quality: s.quality(isExpensiveNetwork: isExpensiveNetwork), allowComposition: true)
            try await engine.load(video: video, resource: resource, policy: policy, startAt: start, autoplay: autoplay)
            try Task.checkCancellation()
            await postLoad(video: video, resource: resource, settings: s)
        } catch is CancellationError {
            // Superseded by a newer selection.
        } catch {
            engine.fail(PlaybackError(error))
        }
    }

    private func postLoad(video: Video, resource: PlaybackResource, settings s: AppSettings) async {
        engine.skipRanges = suppression.advertisementRanges(in: resource, enabled: s.adSuppression)
            + skipEngine.skipRanges(for: resource, categories: s.skipCategories, enabled: s.sponsorSkipping)
        nowPlaying.setItem(video, artworkURL: resource.artworkURL, duration: engine.duration, position: engine.currentTime,
                           rate: engine.rate, isPlaying: engine.state.isActivelyPlaying)
        updateNowPlayingAvailability()
        updateSurface()

        if let hls = resource.videoStreams.first(where: \.isHLS) {
            let manifests = self.manifests
            hlsTask = Task { [weak self] in
                guard let heights = try? await manifests.variantHeights(for: hls.url, userAgent: resource.httpUserAgent), !Task.isCancelled else { return }
                self?.engine.setAvailableHLSHeights(heights)
            }
        }
        await subtitles.configure(
            resource: resource, item: engine.player?.currentItem,
            preference: CaptionPreference(enabled: s.captionsEnabled, languageCode: s.captionLanguage))
    }

    private func resumeStart(for video: Video, explicit: Duration?) async -> Duration? {
        if let explicit { return explicit }
        guard settings.settings.historyEnabled, let saved = await history.position(for: video.id) else { return nil }
        if let f = saved.fraction, f > settings.settings.restartThreshold { return nil }
        return saved.position > .seconds(5) ? saved.position : nil
    }

    // MARK: Engine events

    private func wire() {
        engine.onNotification = { [weak self] n in self?.handle(n) }
        queue.onChange = { [weak self] _ in
            self?.updateNowPlayingAvailability()
            self?.persistSession()
        }
        sleepTimer.onFire = { [weak self] in self?.engine.pause() }

        nowPlaying.bind(.init(
            play: { [weak self] in self?.resumePlayback() },
            pause: { [weak self] in self?.pausePlayback() },
            toggle: { [weak self] in self?.togglePlayPause() },
            seekTo: { [weak self] t in Task { await self?.engine.seek(to: t) } },
            skip: { [weak self] d in Task { await self?.engine.seek(by: d) } },
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() }))

        audio.onInterruptionBegan = { [weak self] in
            guard let self else { return }
            self.interrupted = true
            self.resumeAfterInterruption = self.engine.state.isActivelyPlaying || self.engine.wantsToPlay
        }
        audio.onInterruptionEnded = { [weak self] shouldResume in
            guard let self else { return }
            self.interrupted = false
            if shouldResume, self.resumeAfterInterruption { self.engine.play() }
            self.resumeAfterInterruption = false
        }
        audio.onRouteBecameUnavailable = { [weak self] in self?.engine.pause() }
        audio.onMediaServicesReset = { [weak self] in self?.engine.pause() }

        pip.onRestoreUserInterface = { [weak self] in self?.isPlayerPresented = true }
        pip.onStateChange = { [weak self] in self?.updateSurface() }

        videoView.setPlayer(engine.player, attached: true)
        pip.attach(layer: videoView.playerLayer)
    }

    private func handle(_ n: EngineNotification) {
        switch n {
        case .stateChanged(let state):
            nowPlaying.updatePlayback(position: engine.currentTime, duration: engine.duration, rate: engine.rate, isPlaying: state.isActivelyPlaying)
            updateSurface()
            if state == .paused { persistSession() }
        case .progress(let position, _):
            subtitles.update(position: position)
            accumulateWatchTime(position)
            if ContinuousClock.now - lastPersist > .seconds(10) { persistSession() }
        case .seeked(let t):
            lastProgress = t
            nowPlaying.updatePlayback(position: t, duration: engine.duration, rate: engine.rate, isPlaying: engine.state.isActivelyPlaying)
        case .rateChanged(let rate):
            settings.settings.playbackSpeed = rate
            nowPlaying.updatePlayback(position: engine.currentTime, duration: engine.duration, rate: rate, isPlaying: engine.state.isActivelyPlaying)
        case .ended:
            handleEnded()
        case .itemLoaded:
            break
        }
    }

    private func handleEnded() {
        if let video = queue.queue.current, settings.settings.historyEnabled {
            let end = engine.duration ?? engine.currentTime
            Task { [history] in await history.updatePosition(videoID: video.id, position: end, duration: end) }
        }
        if sleepTimer.consumeVideoEnd() { return }
        if let next = queue.advance() {
            startLoad(next, startAt: nil, autoplay: true)
        } else if let candidate = autoplayCandidate() {
            queue.start(with: candidate)
            startLoad(candidate, startAt: nil, autoplay: true)
        } else {
            nowPlaying.updatePlayback(position: engine.currentTime, duration: engine.duration, rate: engine.rate, isPlaying: false)
            audio.deactivate()
        }
    }

    private func autoplayCandidate() -> Video? {
        guard settings.settings.autoplay else { return nil }
        let current = queue.queue.current?.id
        let played = Set(queue.queue.previous.map(\.id))
        return details?.related.first { $0.id != current && !played.contains($0.id) }
    }

    /// A video enters history only after meaningful viewing, not when its screen opens (ADR §75).
    private func accumulateWatchTime(_ position: Duration) {
        defer { lastProgress = position }
        guard engine.state == .playing, let last = lastProgress else { return }
        let delta = position.totalSeconds - last.totalSeconds
        if delta > 0, delta < 5 { watched += delta }
        guard !didRecordHistory, watched >= 10, settings.settings.historyEnabled, let video = queue.queue.current else { return }
        didRecordHistory = true
        let duration = engine.duration
        Task { [history] in await history.recordWatch(video: video, position: position, duration: duration) }
    }

    // MARK: Persistence & surfaces

    private func persistSession() {
        lastPersist = .now
        let q = queue.queue
        guard let current = q.current else { return }
        let session = PersistedSession(
            queue: q, position: engine.currentTime.totalSeconds, rate: engine.rate, quality: engine.quality,
            captionsEnabled: subtitles.selection != .off, captionLanguage: settings.settings.captionLanguage)
        let position = engine.currentTime, duration = engine.duration
        let record = settings.settings.historyEnabled && didRecordHistory
        Task { [sessionStore, history] in
            await sessionStore.save(session)
            if record { await history.updatePosition(videoID: current.id, position: position, duration: duration) }
        }
    }

    private func updateNowPlayingAvailability() {
        nowPlaying.setSkipAvailability(next: queue.queue.hasNext, previous: queue.queue.hasPrevious || engine.isMediaLoaded)
    }

    /// Detach the video from the layer in the background unless PiP is (or is about to be) active, so audio keeps
    /// playing without video decoding (ADR §14, §57).
    private func updateSurface() {
        let pipMayTakeOver = settings.settings.automaticPiP && pip.isPossible && engine.state.isActivelyPlaying
        let attach = phase != .background || pip.isActive || pipMayTakeOver
        isVideoSurfaceAttached = attach
        videoView.setPlayer(engine.player, attached: attach)
    }
}

extension PlaybackEngine {
    /// Applies the saved default speed before any media is loaded.
    func setRateIfIdle(_ r: Float) { if !isMediaLoaded { setRate(r) } }
}
