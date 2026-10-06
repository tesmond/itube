import Foundation

public struct ProviderCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let search = ProviderCapabilities(rawValue: 1 << 0)
    public static let suggestions = ProviderCapabilities(rawValue: 1 << 1)
    public static let trending = ProviderCapabilities(rawValue: 1 << 2)
    public static let recommended = ProviderCapabilities(rawValue: 1 << 3)
    public static let subscriptionsFeed = ProviderCapabilities(rawValue: 1 << 4)
    public static let channels = ProviderCapabilities(rawValue: 1 << 5)
    public static let playlists = ProviderCapabilities(rawValue: 1 << 6)
    public static let captions = ProviderCapabilities(rawValue: 1 << 7)
    public static let accounts = ProviderCapabilities(rawValue: 1 << 8)
}

public protocol SearchProvider: Sendable {
    func search(_ request: SearchRequest) async throws -> SearchPage
    func searchSuggestions(for query: String) async throws -> [String]
}

public protocol MetadataProvider: Sendable {
    func details(for id: VideoID) async throws -> VideoDetails
    func trending() async throws -> [Video]
    func recommended() async throws -> [Video]
    func subscriptionsFeed() async throws -> [Video]
    func channelVideos(_ id: ChannelID, continuation: String?) async throws -> ContentPage
    func playlistVideos(_ id: PlaylistID, continuation: String?) async throws -> ContentPage
}

public protocol MediaStreamProvider: Sendable {
    func playbackResource(for id: VideoID) async throws -> PlaybackResource
    /// Drops any cached resource so the next call resolves fresh signed URLs (ADR §49).
    func invalidatePlaybackResource(for id: VideoID) async
}

extension MediaStreamProvider {
    public func invalidatePlaybackResource(for id: VideoID) async {}
}

public typealias ContentProvider = SearchProvider & MetadataProvider & MediaStreamProvider

/// A provider never owns an `AVPlayer` (ADR §6). It only turns a logical video into data.
public protocol VideoProvider: ContentProvider {
    var id: String { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }

    func search(query: String) async throws -> [Video]
}

// Optional capabilities default to "unsupported" so the UI can hide sections gracefully (ADR §29).
extension VideoProvider {
    public func search(query: String) async throws -> [Video] {
        try await search(SearchRequest(query: query, filter: .videos)).videos
    }
    public func searchSuggestions(for query: String) async throws -> [String] { [] }
    public func trending() async throws -> [Video] { throw ProviderError.unsupported }
    public func recommended() async throws -> [Video] { throw ProviderError.unsupported }
    public func subscriptionsFeed() async throws -> [Video] { throw ProviderError.unsupported }
    public func channelVideos(_ id: ChannelID, continuation: String?) async throws -> ContentPage { throw ProviderError.unsupported }
    public func playlistVideos(_ id: PlaylistID, continuation: String?) async throws -> ContentPage { throw ProviderError.unsupported }
}

public struct ProviderRegistry: Sendable {
    public let providers: [any VideoProvider]
    public init(providers: [any VideoProvider]) { self.providers = providers }

    public var primary: (any VideoProvider)? { providers.first }
    public var capabilities: ProviderCapabilities { providers.reduce([]) { $0.union($1.capabilities) } }
    public func provider(id: String) -> (any VideoProvider)? { providers.first { $0.id == id } }
}

/// Build-time provider selection (ADR §27). The core app depends on none of them in particular.
public protocol ProviderSet: Sendable {
    func makeRegistry(http: any HTTPClient, authentication: any AuthenticationProvider) -> ProviderRegistry
}

/// Development / direct-distribution configuration.
public struct FullProviderSet: ProviderSet {
    public init() {}
    public func makeRegistry(http: any HTTPClient, authentication: any AuthenticationProvider) -> ProviderRegistry {
        ProviderRegistry(providers: [YouTubeProvider(http: http, authentication: authentication)])
    }
}

/// An App Store build excludes provider integrations that conflict with service terms (ADR §25–27).
/// With no provider the app shows an empty state instead of failing.
public struct AppStoreProviderSet: ProviderSet {
    public init() {}
    public func makeRegistry(http: any HTTPClient, authentication: any AuthenticationProvider) -> ProviderRegistry {
        ProviderRegistry(providers: [])
    }
}
