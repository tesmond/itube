import Foundation

/// YouTube via the InnerTube JSON API (ADR §6, §25). Isolated behind `VideoProvider`; never owns an `AVPlayer`.
public final class YouTubeProvider: VideoProvider {
    public let id = "youtube"
    public let displayName = "YouTube"
    public let capabilities: ProviderCapabilities = [.search, .suggestions, .trending, .recommended, .subscriptionsFeed, .channels, .playlists, .captions, .accounts]

    private let http: any HTTPClient
    private let authentication: any AuthenticationProvider
    private let config: InnerTubeConfig
    private let playerCache: MetadataCache<VideoID, YouTubeParser.PlayerSnapshot>
    private let now: @Sendable () -> Date

    private enum ClientKind { case web, ios }

    public init(
        http: any HTTPClient, authentication: any AuthenticationProvider,
        config: InnerTubeConfig = .default, now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.http = http; self.authentication = authentication; self.config = config; self.now = now
        self.playerCache = MetadataCache(capacity: 8, ttl: 300, now: now)
    }

    // MARK: Search

    public func search(_ request: SearchRequest) async throws -> SearchPage {
        var body = makeBody(.web)
        if let token = request.continuation {
            body.continuation = token
        } else {
            let q = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty, q.count <= 200 else { return SearchPage(items: []) }
            body.query = q
            body.params = Self.searchFilterParams[request.filter] ?? nil
        }
        let json = try await post("search", client: .web, body: body)
        return SearchPage(items: YouTubeParser.searchItems(json, filter: request.filter), continuation: YouTubeParser.continuation(json))
    }

    private static let searchFilterParams: [SearchFilter: String?] = [
        .all: nil, .videos: "EgIQAQ==", .channels: "EgIQAg==", .playlists: "EgIQAw==",
    ]

    public func searchSuggestions(for query: String) async throws -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count <= 100 else { return [] }
        var comps = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        comps.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "ds", value: "yt"), URLQueryItem(name: "q", value: q)]
        guard let url = comps.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(config.web.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await http.data(for: request)
        guard let json = try? JSONValue.decode(data), let list = json[1]?.array else { return [] }
        return list.compactMap(\.string).prefix(10).map { $0 }
    }

    // MARK: Metadata

    public func details(for id: VideoID) async throws -> VideoDetails {
        async let snapshotTask = snapshot(for: id)
        async let relatedTask = related(for: id)
        let snapshot = try await snapshotTask
        let related = (try? await relatedTask) ?? []
        return VideoDetails(video: snapshot.video, description: snapshot.description, related: related)
    }

    private func related(for id: VideoID) async throws -> [Video] {
        var body = makeBody(.web)
        body.videoId = id.rawValue
        let json = try await post("next", client: .web, body: body)
        return YouTubeParser.videos(json, excluding: id)
    }

    public func trending() async throws -> [Video] {
        try await browseVideos(browseId: "FEtrending", authenticated: false)
    }

    public func recommended() async throws -> [Video] {
        guard await authentication.isSignedIn else { throw ProviderError.authenticationRequired }
        return try await browseVideos(browseId: "FEwhat_to_watch", authenticated: true)
    }

    public func subscriptionsFeed() async throws -> [Video] {
        guard await authentication.isSignedIn else { throw ProviderError.authenticationRequired }
        return try await browseVideos(browseId: "FEsubscriptions", authenticated: true)
    }

    public func channelVideos(_ id: ChannelID, continuation: String?) async throws -> ContentPage {
        try await browsePage(browseId: id.rawValue, params: "EgZ2aWRlb3PyBgQKAjoA", continuation: continuation)
    }

    public func playlistVideos(_ id: PlaylistID, continuation: String?) async throws -> ContentPage {
        try await browsePage(browseId: "VL" + id.rawValue, params: nil, continuation: continuation)
    }

    private func browseVideos(browseId: String, authenticated: Bool) async throws -> [Video] {
        var body = makeBody(.web)
        body.browseId = browseId
        let json = try await post("browse", client: .web, body: body, authenticated: authenticated)
        return YouTubeParser.videos(json)
    }

    private func browsePage(browseId: String, params: String?, continuation: String?) async throws -> ContentPage {
        var body = makeBody(.web)
        if let continuation { body.continuation = continuation } else { body.browseId = browseId; body.params = params }
        let json = try await post("browse", client: .web, body: body)
        return ContentPage(videos: YouTubeParser.videos(json), continuation: YouTubeParser.continuation(json))
    }

    // MARK: Playback

    public func playbackResource(for id: VideoID) async throws -> PlaybackResource {
        try await snapshot(for: id).resource
    }

    public func invalidatePlaybackResource(for id: VideoID) async {
        await playerCache.remove(id)
    }

    private func snapshot(for id: VideoID) async throws -> YouTubeParser.PlayerSnapshot {
        guard id.isWellFormed else { throw ProviderError.notFound }
        if let hit = await playerCache.value(for: id), !hit.resource.isExpired(now: now()) { return hit }

        var body = makeBody(.ios)
        body.videoId = id.rawValue
        body.contentCheckOk = true
        body.racyCheckOk = true
        let json = try await post("player", client: .ios, body: body)
        let started = now()
        let snapshot = try YouTubeParser.playerSnapshot(json, requestedID: id, now: started, userAgent: config.ios.userAgent)

        // Never cache longer than the signed URLs live (ADR §41).
        let remaining = snapshot.resource.expiresAt.map { $0.timeIntervalSince(started) - 60 } ?? 300
        if remaining > 30 { await playerCache.insert(snapshot, for: id, ttl: min(300, remaining)) }
        return snapshot
    }

    // MARK: Transport

    private func makeBody(_ kind: ClientKind) -> InnerTubeBody {
        InnerTubeBody(client: kind == .web ? config.web : config.ios, config: config)
    }

    private func post(_ endpoint: String, client kind: ClientKind, body: InnerTubeBody, authenticated: Bool = false) async throws -> JSONValue {
        let client = kind == .web ? config.web : config.ios
        var comps = URLComponents(url: config.baseURL.appending(path: endpoint), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]
        guard let url = comps.url else { throw ProviderError.parsing("bad URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(String(client.nameID), forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(config.origin.absoluteString, forHTTPHeaderField: "Origin")
        if authenticated { request = await authentication.authorize(request) }

        let started = ContinuousClock.now
        do {
            let (data, _) = try await http.data(for: request)
            let json = try JSONValue.decode(data)
            Log.provider.debug("\(endpoint, privacy: .public) ok in \(ContinuousClock.now - started, privacy: .public)")
            return json
        } catch let e as HTTPError {
            if case .status(404) = e { throw ProviderError.notFound }
            throw e
        } catch is DecodingError {
            throw ProviderError.parsing("\(endpoint): response was not valid JSON")
        }
    }
}
