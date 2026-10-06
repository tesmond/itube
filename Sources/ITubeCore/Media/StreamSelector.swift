import Foundation

public struct StreamPolicy: Sendable, Equatable {
    public var quality: VideoQuality
    /// Allow building an `AVMutableComposition` from separate video + audio streams (ADR §10).
    public var allowComposition: Bool
    public init(quality: VideoQuality = .auto, allowComposition: Bool = true) {
        self.quality = quality; self.allowComposition = allowComposition
    }
}

public enum SelectedMedia: Sendable, Equatable {
    case hls(url: URL, userAgent: String?)
    case progressive(url: URL, userAgent: String?)
    case composition(video: URL, audio: URL, userAgent: String?)

    public var isAdaptive: Bool { if case .hls = self { true } else { false } }
}

/// Chooses *what* to play from a resource. Pure and synchronous, so trivially unit-testable (ADR §62).
/// Preference order: HLS (AVPlayer adapts) → muxed MP4 → composition of video-only + audio-only MP4.
public struct StreamSelector: Sendable {
    public init() {}

    public func select(_ resource: PlaybackResource, policy: StreamPolicy) throws -> SelectedMedia {
        let ua = resource.httpUserAgent
        if let hls = resource.videoStreams.first(where: \.isHLS) {
            return .hls(url: hls.url, userAgent: ua)
        }
        let candidates = playableCandidates(resource, allowComposition: policy.allowComposition)
        guard !candidates.isEmpty else {
            throw resource.videoStreams.isEmpty ? PlaybackError.unavailable : PlaybackError.unsupportedCodec
        }
        let chosen: Candidate
        if let cap = policy.quality.height {
            chosen = candidates.filter { $0.height <= cap }.max { $0.height < $1.height } ?? candidates.min { $0.height < $1.height }!
        } else {
            chosen = candidates.max { $0.height < $1.height }!
        }
        switch chosen.kind {
        case .muxed(let s): return .progressive(url: s.url, userAgent: ua)
        case .pair(let v, let a): return .composition(video: v.url, audio: a.url, userAgent: ua)
        }
    }

    /// Qualities the user can pick for a given resource. `hlsHeights` comes from the master playlist when known.
    public func availableQualities(_ resource: PlaybackResource, policy: StreamPolicy, hlsHeights: [Int] = []) -> [VideoQuality] {
        var heights: Set<Int>
        if resource.videoStreams.contains(where: \.isHLS) {
            heights = Set(hlsHeights)
        } else {
            heights = Set(playableCandidates(resource, allowComposition: policy.allowComposition).map(\.height))
        }
        let rungs = Set(heights.compactMap { VideoQuality(height: $0) })
        return [.auto] + rungs.sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: Internals

    private struct Candidate {
        enum Kind { case muxed(MediaStream), pair(MediaStream, MediaStream) }
        let kind: Kind
        let height: Int
    }

    private func playableCandidates(_ resource: PlaybackResource, allowComposition: Bool) -> [Candidate] {
        var out: [Candidate] = resource.videoStreams
            .filter { $0.isMuxed && !$0.isHLS && $0.isNativelyPlayable }
            .map { Candidate(kind: .muxed($0), height: $0.qualityHeight ?? 0) }

        if allowComposition, let audio = bestAudio(resource) {
            out += resource.videoStreams
                .filter { $0.hasVideo && !$0.hasAudio && $0.isNativelyPlayable && $0.container == .mp4 }
                .map { Candidate(kind: .pair($0, audio), height: $0.qualityHeight ?? 0) }
        }
        return out
    }

    private func bestAudio(_ resource: PlaybackResource) -> MediaStream? {
        resource.audioStreams
            .filter { $0.isNativelyPlayable && $0.container == .m4a }
            .max { ($0.isDefaultAudio ? 1 : 0, $0.bitrate ?? 0) < ($1.isDefaultAudio ? 1 : 0, $1.bitrate ?? 0) }
    }
}
