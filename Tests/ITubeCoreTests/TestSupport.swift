import AVFoundation
import Foundation
@testable import ITubeCore

func fixture(_ name: String, _ ext: String = "json") -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
          let data = try? Data(contentsOf: url) else { fatalError("Missing fixture \(name).\(ext)") }
    return data
}

func fixtureJSON(_ name: String) throws -> JSONValue { try JSONValue.decode(fixture(name)) }

/// Records requests and answers with a closure. An actor, so tests need no locks.
actor MockHTTPClient: HTTPClient {
    typealias Responder = @Sendable (URLRequest) throws -> (Data, Int)
    private var responder: Responder
    private(set) var requests: [URLRequest] = []

    init(_ responder: @escaping Responder) { self.responder = responder }

    func setResponder(_ r: @escaping Responder) { responder = r }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (data, code) = try responder(request)
        guard (200..<300).contains(code) else { throw HTTPError.status(code) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

func makeVideo(_ id: String = "dQw4w9WgXcQ", title: String = "Title", duration: Duration? = .seconds(212)) -> Video {
    Video(id: VideoID(id), title: title, channel: ChannelSummary(id: "UCabc123", name: "Chan"), duration: duration)
}

func stream(_ id: String, video: Bool = true, audio: Bool = false, height: Int? = nil, container: MediaStream.Container = .mp4,
            codecs: [String] = ["avc1.640028"], hls: Bool = false, isDefaultAudio: Bool = true, bitrate: Int? = nil) -> MediaStream {
    MediaStream(id: id, url: URL(string: "https://cdn.example.com/\(id)")!, container: hls ? .hls : container,
                hasVideo: video, hasAudio: audio, width: height.map { $0 * 16 / 9 }, height: height, bitrate: bitrate,
                codecs: codecs, isDefaultAudio: isDefaultAudio)
}

func makeResource(_ id: String = "dQw4w9WgXcQ", streams: [MediaStream], audio: [MediaStream] = [], expiresAt: Date? = nil,
                  segments: [MediaSegment] = [], duration: Duration? = .seconds(212)) -> PlaybackResource {
    PlaybackResource(videoID: VideoID(id), title: "T", videoStreams: streams, audioStreams: audio, segments: segments,
                     duration: duration, expiresAt: expiresAt, httpUserAgent: "UA")
}

/// Deterministic stand-in for AVFoundation (ADR §62).
@MainActor
final class FakeBackend: PlayerBackend {
    let events: AsyncStream<PlayerEvent>
    private let continuation: AsyncStream<PlayerEvent>.Continuation
    var avPlayer: AVPlayer? { nil }

    struct Load: Equatable { let media: SelectedMedia; let startAt: Duration?; let quality: VideoQuality }
    var loads: [Load] = []
    var loadError: (any Error)?
    var plays: [Float] = []
    var pauses = 0
    var seeks: [Duration] = []
    var rates: [Float] = []
    var appliedQualities: [VideoQuality] = []
    var stopped = 0
    var isShutDown = false
    var intervals: [Double] = []

    init() { (events, continuation) = AsyncStream<PlayerEvent>.makeStream(bufferingPolicy: .bufferingNewest(32)) }

    func send(_ e: PlayerEvent) { continuation.yield(e) }

    func load(_ media: SelectedMedia, startAt: Duration?, quality: VideoQuality) async throws {
        if let loadError { throw loadError }
        loads.append(Load(media: media, startAt: startAt, quality: quality))
    }
    func play(rate: Float) { plays.append(rate) }
    func pause() { pauses += 1 }
    func setRate(_ rate: Float) { rates.append(rate) }
    func seek(to time: Duration) async { seeks.append(time) }
    func applyQuality(_ quality: VideoQuality) { appliedQualities.append(quality) }
    func setTimeObserverInterval(_ seconds: Double) { intervals.append(seconds) }
    func stop() { stopped += 1 }
    func shutdown() { isShutDown = true; continuation.finish() }
}

/// Lets the engine's event loop (and any hops off the main actor) run.
@MainActor func settle() async {
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(40))
}

/// Polls until `condition` holds (or 3 s pass). Returns whether it held.
@MainActor @discardableResult
func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<150 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

actor FakeResolver: StreamResolving {
    private var resources: [VideoID: PlaybackResource] = [:]
    private(set) var calls: [(id: VideoID, forceRefresh: Bool)] = []
    var failure: (any Error)?

    func set(_ r: PlaybackResource) { resources[r.videoID] = r }
    func setFailure(_ e: (any Error)?) { failure = e }

    func resolve(_ id: VideoID, forceRefresh: Bool, adSuppression: Bool) async throws -> PlaybackResource {
        calls.append((id, forceRefresh))
        if let failure { throw failure }
        guard let r = resources[id] else { throw PlaybackError.unavailable }
        return r
    }
}

final class InMemorySecrets: SecretStoring, @unchecked Sendable {
    // Test double used from a single actor (YouTubeAuthentication); no cross-thread access.
    private var items: [String: Data] = [:]
    func read(account: String) -> Data? { items[account] }
    func write(_ data: Data, account: String) throws { items[account] = data }
    func delete(account: String) { items[account] = nil }
}
