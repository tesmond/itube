import Foundation
import Observation

/// Search (ADR §28). Cancellation is structural: callers cancel their `Task` and the request is cancelled.
public struct SearchService: Sendable {
    private let registry: ProviderRegistry
    public init(registry: ProviderRegistry) { self.registry = registry }

    public var isAvailable: Bool { registry.primary != nil }

    public func search(_ request: SearchRequest) async throws -> SearchPage {
        guard let p = registry.primary else { throw ProviderError.unsupported }
        return try await p.search(request)
    }

    public func suggestions(for query: String) async throws -> [String] {
        guard let p = registry.primary, p.capabilities.contains(.suggestions) else { return [] }
        return try await p.searchSuggestions(for: query)
    }
}

/// Metadata and feeds, with small bounded TTL caches (ADR §41, §55, §56).
public struct VideoService: Sendable {
    private let registry: ProviderRegistry
    private let detailsCache = MetadataCache<VideoID, VideoDetails>(capacity: 32, ttl: 600)
    private let feedCache = MetadataCache<String, [Video]>(capacity: 8, ttl: 300)

    public init(registry: ProviderRegistry) { self.registry = registry }

    public var capabilities: ProviderCapabilities { registry.capabilities }

    public func details(for id: VideoID) async throws -> VideoDetails {
        if let hit = await detailsCache.value(for: id) { return hit }
        guard let p = registry.primary else { throw ProviderError.unsupported }
        let d = try await p.details(for: id)
        await detailsCache.insert(d, for: id)
        return d
    }

    public func trending() async throws -> [Video] { try await feed("trending") { try await $0.trending() } }
    public func recommended() async throws -> [Video] { try await feed("recommended") { try await $0.recommended() } }
    public func subscriptionsFeed() async throws -> [Video] { try await feed("subscriptions") { try await $0.subscriptionsFeed() } }

    public func channelVideos(_ id: ChannelID, continuation: String? = nil) async throws -> ContentPage {
        guard let p = registry.primary else { throw ProviderError.unsupported }
        return try await p.channelVideos(id, continuation: continuation)
    }

    public func playlistVideos(_ id: PlaylistID, continuation: String? = nil) async throws -> ContentPage {
        guard let p = registry.primary else { throw ProviderError.unsupported }
        return try await p.playlistVideos(id, continuation: continuation)
    }

    public func clearCaches() async {
        await detailsCache.removeAll()
        await feedCache.removeAll()
    }

    private func feed(_ key: String, _ load: @Sendable (any VideoProvider) async throws -> [Video]) async throws -> [Video] {
        if let hit = await feedCache.value(for: key) { return hit }
        guard let p = registry.primary else { throw ProviderError.unsupported }
        let videos = try await load(p)
        await feedCache.insert(videos, for: key)
        return videos
    }
}

/// Observable sign-in state for the UI. Credentials themselves never leave `AuthenticationProvider`.
@MainActor @Observable
public final class AccountModel {
    public private(set) var isSignedIn = false
    @ObservationIgnored private let authentication: any AuthenticationProvider
    @ObservationIgnored private let videos: VideoService

    public init(authentication: any AuthenticationProvider, videos: VideoService) {
        self.authentication = authentication; self.videos = videos
    }

    public func refresh() async { isSignedIn = await authentication.isSignedIn }

    public func signIn(cookies: [StoredCookie]) async throws {
        try await authentication.signIn(cookies: cookies)
        await videos.clearCaches()
        await refresh()
    }

    public func signOut() async {
        await authentication.signOut()
        await videos.clearCaches()
        await refresh()
    }
}
