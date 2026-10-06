import Foundation
import UIKit

/// Explicit dependency container (ADR §68). No global singletons beyond Apple's own system ones.
@MainActor
public struct AppEnvironment {
    public let httpClient: any HTTPClient
    public let providerRegistry: ProviderRegistry
    public let authentication: any AuthenticationProvider
    public let account: AccountModel
    public let settings: SettingsManager
    public let coordinator: PlaybackCoordinator
    public let playbackEngine: PlaybackEngine
    public let videoService: VideoService
    public let searchService: SearchService
    public let historyStore: any HistoryStoring
    public let libraryStore: any LibraryStoring
    public let sessionStore: any SessionStoring
    public let imageLoader: ImageLoader
    public let diagnostics: DiagnosticsCenter
    private let sessionClient: URLSessionHTTPClient

    public static func live(providers: any ProviderSet = FullProviderSet(), inMemory: Bool = false) throws -> AppEnvironment {
        // Policy is outermost so blocked hosts never consume retries; retry wraps the raw session.
        let session = URLSessionHTTPClient()
        let http = PolicyEnforcingHTTPClient(base: RetryingHTTPClient(base: session), policy: DomainDenylistPolicy())

        let authentication: any AuthenticationProvider = YouTubeAuthentication()
        let registry = providers.makeRegistry(http: http, authentication: authentication)
        let diagnostics = DiagnosticsCenter()
        let persistence = try PersistenceStack.make(inMemory: inMemory)
        let settings = SettingsManager()
        let images = ImageLoader(http: http)
        let videos = VideoService(registry: registry)
        let suppression = AdSuppressionEngine()
        let resolver = StreamResolver(registry: registry, suppression: suppression, diagnostics: diagnostics)

        let coordinator = PlaybackCoordinator(
            backend: AVPlayerBackend(), resolver: resolver, videos: videos, history: persistence.history,
            sessionStore: persistence.session, settings: settings, http: http, images: images,
            suppression: suppression, diagnostics: diagnostics)

        return AppEnvironment(
            httpClient: http, providerRegistry: registry, authentication: authentication,
            account: AccountModel(authentication: authentication, videos: videos), settings: settings,
            coordinator: coordinator, playbackEngine: coordinator.engine, videoService: videos,
            searchService: SearchService(registry: registry), historyStore: persistence.history,
            libraryStore: persistence.library, sessionStore: persistence.session, imageLoader: images, diagnostics: diagnostics,
            sessionClient: session)
    }

    /// Clears nonessential memory caches (ADR §56). Playback is untouched.
    public func handleMemoryWarning() async {
        await imageLoader.removeAll()
        await videoService.clearCaches()
    }

    public func clearCaches() async { await handleMemoryWarning(); sessionClient.clearCache() }
}

/// `itube://video/{id}` (ADR §71). IDs are validated; anything else is ignored.
public enum DeepLink: Equatable, Sendable {
    case video(VideoID)

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "itube", url.host()?.lowercased() == "video" else { return nil }
        let id = VideoID(url.lastPathComponent)
        guard id.isWellFormed else { return nil }
        self = .video(id)
    }
}
