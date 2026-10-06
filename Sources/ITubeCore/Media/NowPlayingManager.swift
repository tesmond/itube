import Foundation
import MediaPlayer
import UIKit

/// Lock Screen / Control Centre integration (ADR §16, §17). Commands drive the *same* engine as the UI.
@MainActor
public final class NowPlayingManager {
    public struct Handlers: Sendable {
        public var play: @MainActor () -> Void
        public var pause: @MainActor () -> Void
        public var toggle: @MainActor () -> Void
        public var seekTo: @MainActor (Duration) -> Void
        public var skip: @MainActor (Duration) -> Void
        public var next: @MainActor () -> Void
        public var previous: @MainActor () -> Void
        public init(play: @escaping @MainActor () -> Void, pause: @escaping @MainActor () -> Void, toggle: @escaping @MainActor () -> Void,
                    seekTo: @escaping @MainActor (Duration) -> Void, skip: @escaping @MainActor (Duration) -> Void,
                    next: @escaping @MainActor () -> Void, previous: @escaping @MainActor () -> Void) {
            self.play = play; self.pause = pause; self.toggle = toggle; self.seekTo = seekTo
            self.skip = skip; self.next = next; self.previous = previous
        }
    }

    private let center: MPNowPlayingInfoCenter
    private let commands: MPRemoteCommandCenter
    private let images: ImageLoader?
    private var registrations: [(command: MPRemoteCommand, token: Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var info: [String: Any] = [:]
    private var currentVideoID: VideoID?

    public init(images: ImageLoader?, center: MPNowPlayingInfoCenter = .default(), commands: MPRemoteCommandCenter = .shared()) {
        self.images = images; self.center = center; self.commands = commands
    }

    public func bind(_ h: Handlers) {
        unbind()
        register(commands.playCommand) { h.play() }
        register(commands.pauseCommand) { h.pause() }
        register(commands.togglePlayPauseCommand) { h.toggle() }
        register(commands.nextTrackCommand) { h.next() }
        register(commands.previousTrackCommand) { h.previous() }

        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.preferredIntervals = [15]
        for (cmd, sign) in [(commands.skipForwardCommand, 1.0), (commands.skipBackwardCommand, -1.0)] {
            cmd.isEnabled = true
            let t = cmd.addTarget { event in
                let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
                Task { @MainActor in h.skip(Duration(seconds: abs(interval)) * sign) }
                return .success
            }
            registrations.append((cmd, t))
        }

        commands.changePlaybackPositionCommand.isEnabled = true
        let seek = commands.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = e.positionTime
            Task { @MainActor in h.seekTo(Duration(seconds: position)) }
            return .success
        }
        registrations.append((commands.changePlaybackPositionCommand, seek))
        setSkipAvailability(next: false, previous: false)
    }

    public func setItem(_ video: Video, artworkURL: URL?, duration: Duration?, position: Duration, rate: Float, isPlaying: Bool) {
        artworkTask?.cancel()
        currentVideoID = video.id
        info = Self.makeInfo(video: video, duration: duration, position: position, rate: rate, isPlaying: isPlaying)
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused

        guard let artworkURL = artworkURL ?? video.thumbnail(forWidth: 600)?.url, let images else { return }
        let id = video.id
        artworkTask = Task { [weak self] in
            guard let image = try? await images.image(for: artworkURL, maxPixelSize: 600), !Task.isCancelled else { return }
            guard let self, self.currentVideoID == id else { return }
            self.info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.center.nowPlayingInfo = self.info
        }
    }

    /// Only updated on state changes and seeks — the system extrapolates elapsed time from the rate, so no ticking (ADR §57).
    public func updatePlayback(position: Duration, duration: Duration?, rate: Float, isPlaying: Bool) {
        guard currentVideoID != nil else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position.totalSeconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(rate)
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration.totalSeconds }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    public func setSkipAvailability(next: Bool, previous: Bool) {
        commands.nextTrackCommand.isEnabled = next
        commands.previousTrackCommand.isEnabled = previous
    }

    public func clear() {
        artworkTask?.cancel(); artworkTask = nil
        currentVideoID = nil; info = [:]
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    public func shutdown() { clear(); unbind() }

    private func register(_ command: MPRemoteCommand, _ handler: @escaping @MainActor () -> Void) {
        command.isEnabled = true
        let token = command.addTarget { _ in
            Task { @MainActor in handler() }
            return .success
        }
        registrations.append((command, token))
    }

    private func unbind() {
        for r in registrations { r.command.removeTarget(r.token) }
        registrations.removeAll()
    }

    static func makeInfo(video: Video, duration: Duration?, position: Duration, rate: Float, isPlaying: Bool) -> [String: Any] {
        var d: [String: Any] = [
            MPMediaItemPropertyTitle: video.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position.totalSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        if let name = video.channel?.name, !name.isEmpty { d[MPMediaItemPropertyArtist] = name }
        if let duration = duration ?? video.duration { d[MPMediaItemPropertyPlaybackDuration] = duration.totalSeconds }
        return d
    }
}
