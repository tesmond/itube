import Foundation

public struct Thumbnail: Sendable, Hashable, Codable {
    public let url: URL
    public let width: Int?
    public let height: Int?
    public init(url: URL, width: Int? = nil, height: Int? = nil) {
        self.url = url; self.width = width; self.height = height
    }
}

public struct ChannelSummary: Sendable, Hashable, Codable, Identifiable {
    public let id: ChannelID
    public let name: String
    public let thumbnailURL: URL?
    public let subscriberText: String?
    public init(id: ChannelID, name: String, thumbnailURL: URL? = nil, subscriberText: String? = nil) {
        self.id = id; self.name = name; self.thumbnailURL = thumbnailURL; self.subscriberText = subscriberText
    }
}

public struct PlaylistSummary: Sendable, Hashable, Codable, Identifiable {
    public let id: PlaylistID
    public let title: String
    public let videoCountText: String?
    public let thumbnails: [Thumbnail]
    public init(id: PlaylistID, title: String, videoCountText: String? = nil, thumbnails: [Thumbnail] = []) {
        self.id = id; self.title = title; self.videoCountText = videoCountText; self.thumbnails = thumbnails
    }
}

/// Provider-independent video model (ADR §5).
public struct Video: Identifiable, Sendable, Hashable, Codable {
    public let id: VideoID
    public let title: String
    public let channel: ChannelSummary?
    public let duration: Duration?
    public let thumbnails: [Thumbnail]
    public let publishedAt: Date?
    public let publishedText: String?
    public let viewCount: Int?

    public init(
        id: VideoID, title: String, channel: ChannelSummary? = nil, duration: Duration? = nil,
        thumbnails: [Thumbnail] = [], publishedAt: Date? = nil, publishedText: String? = nil, viewCount: Int? = nil
    ) {
        self.id = id; self.title = title; self.channel = channel; self.duration = duration
        self.thumbnails = thumbnails; self.publishedAt = publishedAt; self.publishedText = publishedText
        self.viewCount = viewCount
    }

    /// Best thumbnail for a requested pixel width (smallest that is large enough, else the largest).
    public func thumbnail(forWidth width: CGFloat) -> Thumbnail? {
        let sorted = thumbnails.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        return sorted.first { CGFloat($0.width ?? 0) >= width } ?? sorted.last
    }

    /// A copy that keeps a single thumbnail — used when persisting so history rows stay small.
    public func compacted(thumbnailWidth: CGFloat = 480) -> Video {
        Video(id: id, title: title, channel: channel, duration: duration,
              thumbnails: thumbnail(forWidth: thumbnailWidth).map { [$0] } ?? [],
              publishedAt: publishedAt, publishedText: publishedText, viewCount: viewCount)
    }
}

public struct VideoDetails: Sendable, Equatable {
    public let video: Video
    public let description: String
    public let related: [Video]
    public init(video: Video, description: String = "", related: [Video] = []) {
        self.video = video; self.description = description; self.related = related
    }
}

public enum SearchFilter: String, Sendable, CaseIterable, Codable {
    case all, videos, channels, playlists
}

public enum SearchItem: Sendable, Hashable, Identifiable {
    case video(Video)
    case channel(ChannelSummary)
    case playlist(PlaylistSummary)

    public var id: String {
        switch self {
        case .video(let v): "v:\(v.id)"
        case .channel(let c): "c:\(c.id)"
        case .playlist(let p): "p:\(p.id)"
        }
    }
}

public struct SearchRequest: Sendable, Equatable {
    public var query: String
    public var filter: SearchFilter
    public var continuation: String?
    public init(query: String, filter: SearchFilter = .all, continuation: String? = nil) {
        self.query = query; self.filter = filter; self.continuation = continuation
    }
}

public struct SearchPage: Sendable, Equatable {
    public var items: [SearchItem]
    public var continuation: String?
    public init(items: [SearchItem], continuation: String? = nil) {
        self.items = items; self.continuation = continuation
    }
    public var videos: [Video] { items.compactMap { if case .video(let v) = $0 { v } else { nil } } }
}

public struct ContentPage: Sendable, Equatable {
    public var title: String?
    public var videos: [Video]
    public var continuation: String?
    public init(title: String? = nil, videos: [Video], continuation: String? = nil) {
        self.title = title; self.videos = videos; self.continuation = continuation
    }
}
