import AVFoundation
import Foundation

public enum TimeControl: Sendable, Equatable { case paused, waiting, playing }

public enum PlayerEvent: Sendable, Equatable {
    case timeControl(TimeControl)
    case time(Duration)
    case duration(Duration?)
    case ended
    case stalled
    case failed(PlaybackError)
}

/// The seam between `PlaybackEngine` and AVFoundation, so engine logic is testable without playing video (ADR §62).
@MainActor
public protocol PlayerBackend: AnyObject {
    /// Single-consumer, bounded event stream.
    var events: AsyncStream<PlayerEvent> { get }
    var avPlayer: AVPlayer? { get }

    /// Prepares `media` and swaps it in only once it is ready; the previous item keeps playing until then (ADR §8).
    func load(_ media: SelectedMedia, startAt: Duration?, quality: VideoQuality) async throws
    func play(rate: Float)
    func pause()
    func setRate(_ rate: Float)
    func seek(to time: Duration) async
    func applyQuality(_ quality: VideoQuality)
    func setTimeObserverInterval(_ seconds: Double)
    func stop()
    func shutdown()
}
