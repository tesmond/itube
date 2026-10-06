import AVFoundation
import Foundation

/// The one `AVPlayer` for the whole app (ADR §7, §79). It is long-lived and independent of any SwiftUI view.
@MainActor
public final class AVPlayerBackend: PlayerBackend {
    public let player = AVPlayer()
    public let events: AsyncStream<PlayerEvent>
    public var avPlayer: AVPlayer? { player }

    private let continuation: AsyncStream<PlayerEvent>.Continuation
    private var playerObservations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var notificationTokens: [any NSObjectProtocol] = []
    private var timeObserver: Any?
    private var timeInterval: Double = 0.5
    private var isShutDown = false

    public init() {
        let (stream, continuation) = AsyncStream<PlayerEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.events = stream
        self.continuation = continuation

        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true                    // AirPlay video (ADR §33)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true

        let cont = continuation
        playerObservations.append(player.observe(\.timeControlStatus, options: [.new]) { _, change in
            guard let status = change.newValue else { return }
            cont.yield(.timeControl(Self.map(status)))
        })
        installTimeObserver()
    }

    // The owner must call `shutdown()`; the observers capture only the Sendable continuation, never `self`.

    public func load(_ media: SelectedMedia, startAt: Duration?, quality: VideoQuality) async throws {
        let asset = try await PlaybackAssetFactory.makeAsset(for: media)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30        // bounded buffering (ADR §56, §57)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        Self.apply(quality, to: item)
        try Task.checkCancellation()

        if let startAt, startAt > .zero {
            _ = await item.seek(to: CMTime(seconds: startAt.totalSeconds, preferredTimescale: 600))
        }
        try Task.checkCancellation()

        detachItemObservers()
        player.replaceCurrentItem(with: item)
        attachItemObservers(item)
        if let d = try? await asset.load(.duration), d.isNumeric, d.seconds.isFinite, d.seconds > 0 {
            continuation.yield(.duration(Duration(seconds: d.seconds)))
        } else {
            continuation.yield(.duration(nil))   // live or not yet known
        }
    }

    public func play(rate: Float) {
        player.defaultRate = rate
        player.play()
    }

    public func pause() { player.pause() }

    public func setRate(_ rate: Float) {
        player.defaultRate = rate
        if player.timeControlStatus != .paused { player.rate = rate }
    }

    public func seek(to time: Duration) async {
        let target = CMTime(seconds: time.totalSeconds, preferredTimescale: 600)
        _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func applyQuality(_ quality: VideoQuality) {
        if let item = player.currentItem { Self.apply(quality, to: item) }
    }

    public func setTimeObserverInterval(_ seconds: Double) {
        guard seconds != timeInterval, !isShutDown else { return }
        timeInterval = seconds
        installTimeObserver()
    }

    public func stop() {
        player.pause()
        detachItemObservers()
        player.replaceCurrentItem(with: nil)
    }

    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        stop()
        removeTimeObserver()
        playerObservations.forEach { $0.invalidate() }
        playerObservations.removeAll()
        continuation.finish()
    }

    // MARK: Observers

    private func installTimeObserver() {
        removeTimeObserver()
        let cont = continuation
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: timeInterval, preferredTimescale: 600), queue: .main
        ) { time in
            guard time.isNumeric, time.seconds.isFinite else { return }
            cont.yield(.time(Duration(seconds: time.seconds)))
        }
    }

    private func removeTimeObserver() {
        if let token = timeObserver { player.removeTimeObserver(token); timeObserver = nil }
    }

    private func attachItemObservers(_ item: AVPlayerItem) {
        let cont = continuation
        itemObservations.append(item.observe(\.status, options: [.new]) { item, change in
            if change.newValue == .failed { cont.yield(.failed(PlaybackErrorMapper.map(item.error))) }
        })
        itemObservations.append(item.observe(\.duration, options: [.new]) { _, change in
            guard let d = change.newValue, d.isNumeric, d.seconds.isFinite, d.seconds > 0 else { return }
            cont.yield(.duration(Duration(seconds: d.seconds)))
        })
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
            cont.yield(.ended)
        })
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            cont.yield(.failed(PlaybackErrorMapper.map(error)))
        })
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { _ in
            cont.yield(.stalled)
        })
    }

    private func detachItemObservers() {
        itemObservations.forEach { $0.invalidate() }
        itemObservations.removeAll()
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
    }

    // MARK: Helpers

    private nonisolated static func map(_ status: AVPlayer.TimeControlStatus) -> TimeControl {
        switch status {
        case .paused: .paused
        case .waitingToPlayAtSpecifiedRate: .waiting
        case .playing: .playing
        @unknown default: .paused
        }
    }

    /// HLS adapts automatically; a manual cap only bounds what AVPlayer may choose (ADR §9).
    private static func apply(_ quality: VideoQuality, to item: AVPlayerItem) {
        if let h = quality.height {
            let bound = (Double(h) * 16.0 / 9.0).rounded()
            item.preferredMaximumResolution = CGSize(width: bound, height: bound)
        } else {
            item.preferredMaximumResolution = .zero
        }
        item.preferredPeakBitRate = 0
    }
}

/// Maps AVFoundation errors (including HTTP 403 surfaced as CoreMedia -12660) into `PlaybackError`.
public enum PlaybackErrorMapper {
    public static func map(_ error: (any Error)?) -> PlaybackError {
        guard let ns = error as NSError? else { return .playbackFailed }
        let chain = underlyingChain(ns)
        if chain.contains(where: { $0.domain == "CoreMediaErrorDomain" && [-12660, -12939, -16845].contains($0.code) }) { return .streamExpired }
        if chain.contains(where: { $0.domain == NSURLErrorDomain && [NSURLErrorNoPermissionsToReadFile, NSURLErrorFileDoesNotExist].contains($0.code) }) { return .streamExpired }
        if chain.contains(where: { $0.domain == NSURLErrorDomain && [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut].contains($0.code) }) { return .networkUnavailable }
        if chain.contains(where: { $0.domain == AVFoundationErrorDomain && $0.code == AVError.Code.decoderNotFound.rawValue }) { return .unsupportedCodec }
        if chain.contains(where: { $0.domain == AVFoundationErrorDomain && $0.code == AVError.Code.fileFormatNotRecognized.rawValue }) { return .invalidManifest }
        return .playbackFailed
    }

    private static func underlyingChain(_ error: NSError) -> [NSError] {
        var out = [error]
        var current = error
        while let next = current.userInfo[NSUnderlyingErrorKey] as? NSError, out.count < 6 { out.append(next); current = next }
        return out
    }
}

/// Builds the `AVAsset` for a selection. Composition is the last-resort path for separate A/V streams.
@MainActor
enum PlaybackAssetFactory {
    static func makeAsset(for media: SelectedMedia) async throws -> AVAsset {
        switch media {
        case .hls(let url, let ua), .progressive(let url, let ua):
            let asset = urlAsset(url, userAgent: ua)
            try await preflight(asset)
            return asset
        case .composition(let videoURL, let audioURL, let ua):
            let video = urlAsset(videoURL, userAgent: ua)
            let audio = urlAsset(audioURL, userAgent: ua)
            let (vTracks, aTracks, vDur, aDur) = try await (
                video.loadTracks(withMediaType: .video), audio.loadTracks(withMediaType: .audio),
                video.load(.duration), audio.load(.duration))
            guard let vTrack = vTracks.first, let aTrack = aTracks.first else { throw PlaybackError.invalidManifest }
            let duration = CMTimeMinimum(vDur, aDur)
            let composition = AVMutableComposition()
            guard let cv = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let ca = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw PlaybackError.playbackFailed
            }
            let range = CMTimeRange(start: .zero, duration: duration)
            try cv.insertTimeRange(range, of: vTrack, at: .zero)
            try ca.insertTimeRange(range, of: aTrack, at: .zero)
            cv.preferredTransform = try await vTrack.load(.preferredTransform)
            return composition
        }
    }

    private static func urlAsset(_ url: URL, userAgent: String?) -> AVURLAsset {
        var options: [String: Any] = [:]
        if let userAgent { options[AVURLAssetHTTPUserAgentKey] = userAgent }
        return AVURLAsset(url: url, options: options.isEmpty ? nil : options)
    }

    private static func preflight(_ asset: AVURLAsset) async throws {
        let playable = try await asset.load(.isPlayable)
        guard playable else { throw PlaybackError.invalidManifest }
    }
}
